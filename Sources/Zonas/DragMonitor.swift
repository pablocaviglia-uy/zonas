import AppKit
import ApplicationServices

/// Detects window drags and fires the snap.
///
/// This is the heart of the matter and also the only awkward part. macOS
/// **exposes no API** that tells you "the user is moving window X". The closest
/// you can get is this: an event tap that watches the session's mouse events
/// and, on the first movement past the threshold, asks the Accessibility API
/// which window was under the point where the drag started.
///
/// The tap is read-only (`.listenOnly`): it observes events and lets them
/// through untouched. If it intercepted them, any slowness in this code would
/// feel like lag across the whole system.
final class DragMonitor {

    // The key that reveals the zones is `defaults.modifier` in the file, read
    // off the layout this drag is working against. It used to be a `static let`
    // right here, which is where a setting goes to never become settable.

    /// How far the mouse has to move before it counts as a drag and not a click
    /// with an unsteady hand.
    private let dragThreshold: CGFloat = 8

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// A second tap, alive **only** while a snap is being composed.
    ///
    /// It exists because the gesture no longer ends when the button does. Once
    /// the finger is off the trackpad the cursor still has to be followed, and
    /// `mouseMoved` is the only event that says where it went; and Escape has to
    /// be heard, which means `keyDown`.
    ///
    /// Both are things this app has no business seeing when nothing is
    /// happening. A permanent tap on every mouse movement and every keystroke is
    /// exactly the uncomfortable question an open-source window manager should
    /// not invite, and §7's Stage 3 already settles the shape of the answer for
    /// the same reason: a second tap, created when a gesture starts and torn
    /// down when it ends. Outside of a drag, Zonas cannot see either one.
    private var sessionTap: CFMachPort?
    private var sessionSource: CFRunLoopSource?

    private var startPoint: CGPoint?
    private var draggedWindow: AXWindow?
    private var isDragging = false

    /// Whether the zones are on screen — which is the same thing as *a snap is
    /// being composed right now*, and the reason there is no second flag.
    private var isOverlayVisible = false

    /// Whether the mouse button is down, tracked because it is no longer what
    /// ends the gesture and so can no longer be inferred from being called.
    private var isButtonDown = false

    /// The zones the snap will use, kept as state rather than recomputed.
    ///
    /// It has to be state now: the gesture commits when the **modifier** is
    /// released, and by the time that event arrives the modifier is by
    /// definition no longer held — so asking "what is selected" from the
    /// committing event would answer with the modifier down and throw away
    /// everything gathered. What is committed is the last thing that was drawn,
    /// which is the only answer that cannot disagree with the screen.
    private var selected: Set<Int> = []

    /// The usable area of the screen the selection was made on, frozen with it
    /// for the same reason.
    private var selectionArea: CGRect?

    /// Whether the window this drag picked up belongs to an application the
    /// file says to leave alone. It suppresses the overlay — see `handleDrag`.
    private var isExcluded = false

    /// The zones gathered so far, by index into the frozen layout.
    ///
    /// Empty means the ordinary gesture — whatever is under the cursor right
    /// now, and nothing remembered. It fills up only while the span key is held,
    /// and **releasing that key empties it again**, which is the whole way out of
    /// a selection you did not mean: overshoot by one zone, let go, start over.
    /// Without it the only escape from a wrong selection would be to abandon the
    /// drag, because gathering is additive and passing back over a zone a second
    /// time does not remove it. Additive is what makes a sweep predictable; the
    /// escape hatch is what makes additive survivable.
    private var gathered: Set<Int> = []

    /// Whether somebody asked for the tap to be quiet — see `setEnabled`.
    ///
    /// It has to be remembered rather than read back off the port, because the
    /// system disables the tap on its own too and the two are indistinguishable
    /// from the outside. Without it the recovery path below cheerfully undoes
    /// the suspension: measured on this machine, disabling the tap while the
    /// editor opened was followed 48 ms later by a `tapDisabledByUserInput`,
    /// and the handler for that turned the tap straight back on.
    private var isSuspended = false

    /// The layout this drag is working against, frozen when the drag begins.
    ///
    /// A gesture lasts seconds; saving the file takes none. Asking the store
    /// again on every event would let the zones drawn during the drag and the
    /// zone chosen on the drop come from two different versions of the file, and
    /// the user would have no way of telling that is what happened — the window
    /// just lands somewhere else than where the highlight was.
    private var snapshot: Layout?

    private let overlay = OverlayController()

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        // It isn't called twice today, but any periodic re-check added later
        // would leak the previous CFMachPort and leave two live taps receiving
        // everything. One line prevents that.
        stop()

        // `.flagsChanged` is in here so that pressing or releasing a modifier
        // **without moving the mouse** is noticed. Everything this app reacts to
        // is a modifier plus a drag, and until now the only way to find out that
        // a key had gone down was to wait for the next mouse event: hold the
        // window still, press ⇧, and nothing happened until you twitched. With
        // the span key that stops being a wart and becomes unusable, because
        // gathering zones is exactly the gesture where you press a second key
        // with the cursor already parked where you want it.
        //
        // It is not a keyboard tap. `.flagsChanged` carries no character and no
        // key code this app reads — only which modifiers are down — which is
        // also the honest answer to "does this open-source thing listen to
        // everything I type".
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = events.reduce(into: CGEventMask(0)) { $0 |= 1 << $1.rawValue }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DragMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Almost always means the Accessibility permission is missing:
            // without it the system won't let the tap be created and returns
            // nil with no further detail.
            //
            // If this shows up WITH the permission granted in Settings, the
            // suspect isn't the permission but the signature requirement, which
            // is why the fingerprint gets logged here too.
            Log.write("tap: FAILED to create — signature \(signatureFingerprint())")
            Log.write("tap: if the switch is on, compare against "
                      + "`codesign -d -r- /Applications/Zonas.app`")
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                          tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = runLoopSource

        // A tap comes up listening, and a suspension has to survive one being
        // built underneath it. The editor does not need the Accessibility
        // permission to draw, so it can perfectly well be open when the
        // permission watchdog finally gets one — and a tap that came alive
        // inside an open editor is the exact fight `setEnabled` exists to
        // prevent, arriving by the one door that does not go through it.
        if isSuspended { CGEvent.tapEnable(tap: tap, enable: false) }

        Log.write("tap: active, \(isSuspended ? "but suspended" : "listening to the mouse")")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        // The gesture tap outlives the main one otherwise, which would leave the
        // app watching every mouse movement and every keystroke with nothing
        // left that could ever close it.
        stopListeningForTheRest()
        overlay.hide()
    }

    /// Stops and resumes delivery **without taking the tap down**.
    ///
    /// The editor is what needs this. With the tap listening, holding the
    /// modifier inside the editor summons the drag overlay, which then draws the
    /// same zones a hundred levels above the ones you are editing — two pictures
    /// of the same layout fighting over the screen.
    ///
    /// Deliberately not `stop()` followed by `start()`. Creating the tap is the
    /// call that fails when the permission is missing, and it returns `nil` with
    /// no detail; rebuilding it on the way back would hand the editor a way to
    /// leave the app permanently deaf, with the watchdog long since retired and
    /// nothing left to retry it. Disabling a port that already exists cannot
    /// fail, and it is the same call the timeout path already makes.
    func setEnabled(_ enabled: Bool) {
        guard let tap else { return }   // no permission: there is nothing to quieten
        isSuspended = !enabled
        CGEvent.tapEnable(tap: tap, enable: enabled)
        if !enabled { forgetTheDrag() }

        // The port is asked what it thinks, rather than the log repeating what
        // it was told. That is not decoration: what this line was meant to
        // report and what was actually true were different for the first
        // version of this method, and only a line that reads the state back
        // could have said so.
        Log.write("tap: \(enabled ? "resumed" : "suspended") — "
                  + (CGEvent.tapIsEnabled(tap: tap) ? "listening" : "deaf"))
    }

    /// The system took the tap away. Whether to take it back.
    ///
    /// A tap that is off and not turned back on makes the app permanently deaf
    /// with no error anywhere, so the reflex is to re-enable unconditionally —
    /// which is what this used to do, and which quietly cancels a suspension
    /// that is still in force. The distinction the reflex was missing is that
    /// only one of the two disablings was somebody's decision.
    private func revive(_ reason: String) {
        guard !isSuspended else {
            Log.write("tap: disabled by \(reason) while suspended — leaving it off")
            return
        }
        Log.write("tap: disabled by \(reason) — re-enabling")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Back to knowing nothing about any gesture.
    ///
    /// Suspending has to do this as well as dropping does. A drag cannot really
    /// be in progress when the editor opens — the click that opened the menu
    /// ended it — but leaving `isDragging` set means the first event after the
    /// resume is read as the middle of a gesture that began before the editor
    /// existed, against a window that was identified for it.
    private func forgetTheDrag() {
        overlay.hide()
        stopListeningForTheRest()
        isOverlayVisible = false
        isDragging = false
        isExcluded = false
        gathered = []
        selected = []
        selectionArea = nil
        // Cleared, or "the button came up N ms after the last movement" reports
        // the gap since the *previous* gesture's last movement for any gesture
        // that never moved — a number that looks like a measurement, is not one,
        // and reads as 1.7 s of suspicious stillness where the truth is that
        // nothing moved at all.
        lastMovedAt = nil
        pressedAt = nil
        startPoint = nil
        draggedWindow = nil
        snapshot = nil
    }

    // MARK: - The tap that only exists during a gesture

    /// Starts listening to bare mouse movement and to Escape.
    ///
    /// Neither belongs in the permanent tap. `mouseMoved` fires whenever the
    /// pointer moves at all, which is most of the time a Mac is switched on, and
    /// `keyDown` is every keystroke on the machine — for a menu bar app that
    /// somebody has to trust with the Accessibility permission, having those
    /// arrive only between the start of a drag and its snap is worth the two
    /// system calls it costs.
    ///
    /// A failure is not fatal and is not treated as one: the gesture still works
    /// exactly as it did before this existed, you simply cannot move the cursor
    /// with the button up or press Escape. Refusing the whole drag over it would
    /// be a worse trade.
    private func beginListeningForTheRest() {
        guard sessionTap == nil else { return }

        let events: [CGEventType] = [.mouseMoved, .keyDown]
        let mask = events.reduce(into: CGEventMask(0)) { $0 |= 1 << $1.rawValue }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DragMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("tap: could not open the gesture tap — the cursor will not"
                      + " be followed with the button up, and Escape will not cancel")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        sessionTap = tap
        sessionSource = source
    }

    private func stopListeningForTheRest() {
        if let sessionTap { CGEvent.tapEnable(tap: sessionTap, enable: false) }
        if let sessionSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionSource, .commonModes)
        }
        sessionTap = nil
        sessionSource = nil
    }

    // MARK: - Events

    /// The tap runs on the main run loop, so this is already on the UI thread
    /// and can touch the overlay without dispatching.
    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            // Deliberately not logged. A line here is a line for every click
            // anywhere on the machine, which buries the file — the same reason
            // `mouseDragged` is not logged.
            isButtonDown = true
            pressedAt = DispatchTime.now()
            startPoint = event.location
            // A press **during** a live gesture is somebody taking hold again
            // after lifting their finger, so the window already chosen is kept.
            // Looking one up afresh would find whatever is under the cursor now,
            // which after a lift is usually not the window being moved.
            if !isOverlayVisible {
                draggedWindow = nil
                isDragging = false
            }

        case .leftMouseDragged:
            lastMovedAt = DispatchTime.now()
            handleDrag(event)

        // **The button coming up no longer ends anything.** It used to be the
        // whole gesture: press, drag, release, snap. But a trackpad drag is one
        // continuous press with no way to pause, and lifting a finger to
        // reposition it — measured on this machine as a click of 57 ms followed
        // 147 ms later by the real hold — threw the entire gesture away. The
        // zones vanished and the window snapped wherever the cursor happened to
        // be, which is precisely what "it cancels after a second and picks the
        // current zone" was.
        case .leftMouseUp:
            isButtonDown = false
            isDragging = false
            commitIfFinished(at: event.location, flags: event.flags)

        // A modifier moved. `event.location` is the cursor's current position
        // for any event type, so this is the same work a drag event would do —
        // which is the point: pressing the modifier and moving the mouse are two
        // ways of changing the same answer, and only one of them used to be
        // heard.
        case .flagsChanged:
            if isDragging || isOverlayVisible { handleDrag(event) }

        // From the session tap, and only ever while a gesture is live. Once the
        // button is up this is the only thing that says where the cursor went.
        case .mouseMoved:
            if isOverlayVisible { update(at: event.location, flags: event.flags) }

        // Escape, and nothing else is read. It is the only way out now that
        // letting go of the modifier commits rather than cancels.
        case .keyDown:
            if isOverlayVisible, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                abandon("Escape")
            }

        // The system disables the tap if it takes too long to respond. When
        // that happens it has to be re-enabled or the app goes deaf forever.
        //
        // Both are logged, told apart: `byUserInput` is benign and happens all
        // the time, but `byTimeout` means the callback took too long and is the
        // only evidence that would tell whether this should someday move off
        // the main thread. It used to re-enable silently, leaving no trace.
        case .tapDisabledByTimeout:
            revive("TIMEOUT")

        case .tapDisabledByUserInput:
            revive("user input")

        default:
            break
        }
    }

    private func handleDrag(_ event: CGEvent) {
        guard let start = startPoint else { return }
        let current = event.location

        // The window is identified once per gesture, and a gesture now survives
        // the button. Without `!isOverlayVisible` here, the first modifier or
        // movement after a lift walks back in through this branch — the cursor
        // is long past the threshold by then — and looks up whatever is under it
        // now, which after a lift is the desktop or the window underneath.
        if !isDragging, !isOverlayVisible {
            let distance = hypot(current.x - start.x, current.y - start.y)
            guard distance >= dragThreshold else { return }
            isDragging = true
            // The layout is taken here, once, and everything from here to the
            // drop reads this copy.
            snapshot = LayoutStore.shared.layout
            // The window is looked up under the starting point, not the current
            // one: by the time the threshold is crossed the cursor may already
            // be over a different one.
            //
            // The lookup answers with a sentence when it answers with no window,
            // and the sentence is written straight into the log. Every way this
            // stage can decline looks identical from outside the app — you drag,
            // and nothing moves — so a line that says "no window identified"
            // and stops is a line that sends somebody to read the source.
            switch AXWindow.at(cgPoint: start) {
            case .window(let window) where snapshot?.ignores(window.bundleID) == true:
                draggedWindow = nil
                isExcluded = true
                Log.write("drag: leaving \(window.name) alone at \(describe(start))"
                          + " — \(window.bundleID ?? "it") is in the file's ignore list")
            case .window(let window):
                draggedWindow = window
                Log.write("drag: \(window.name) at \(describe(start))")
            case .nothing(let why):
                draggedWindow = nil
                Log.write("drag: nothing to move at \(describe(start)) — \(why)")
            }
        }

        // The overlay shows even when no window was identified. Keeping the two
        // apart is deliberate: if the preview appears but nothing snaps, the
        // problem is in the identification; if nothing appears at all, the
        // problem is earlier, in the tap or in the modifier.
        //
        // **An excluded application is the one exception**, and it is the
        // opposite case rather than the same one. Everywhere else the overlay
        // appears because Zonas does not yet know whether the drop will work;
        // here it knows it will not, because it was told so in the file. Zones
        // lighting up over a window that was never going to move is §3e's lying
        // preview with a different cause — and unlike the diagnostic value of
        // showing it when identification failed, there is nothing to diagnose:
        // the user wrote the line.
        update(at: current, flags: event.flags)
    }

    /// Draws the zones, keeps the selection current, and commits when the
    /// gesture is over.
    ///
    /// Everything that can change the answer comes through here — a drag, a
    /// modifier, a bare mouse movement once the button is up — so the rectangle
    /// on screen and the rectangle the window is given cannot come apart.
    private func update(at point: CGPoint, flags: CGEventFlags) {
        // The overlay shows even when no window was identified. Keeping the two
        // apart is deliberate: if the preview appears but nothing snaps, the
        // problem is in the identification; if nothing appears at all, the
        // problem is earlier, in the tap or in the modifier.
        //
        // **An excluded application is the one exception**, and it is the
        // opposite case rather than the same one. Everywhere else the overlay
        // appears because Zonas does not yet know whether the drop will work;
        // here it knows it will not, because it was told so in the file. Zones
        // lighting up over a window that was never going to move is §3e's lying
        // preview with a different cause — and unlike the diagnostic value of
        // showing it when identification failed, there is nothing to diagnose:
        // the user wrote the line.
        guard let layout = snapshot, !isExcluded, flags.contains(layout.modifier.flags) else {
            commitIfFinished(at: point, flags: flags)
            return
        }
        guard let screen = NSScreen.containing(cgPoint: point) else { return }

        if !isOverlayVisible {
            shownAt = DispatchTime.now()
            Log.write("overlay: showing zones of \"\(layout.name)\"")
            beginListeningForTheRest()
        }
        selectionArea = screen.cgVisibleFrame
        selected = selection(for: layout, at: point, on: screen, flags: flags)
        overlay.show(layout, selecting: selected, on: screen)
        isOverlayVisible = true
    }

    /// Snaps, once the gesture is actually over.
    ///
    /// **It is over when the last of the two goes**: the modifier and the
    /// button. Which one is last is the user's business — letting go of the key
    /// while still holding the window is as ordinary as the other way round —
    /// and waiting for both is what makes the answer the same either way.
    ///
    /// Committing on the modifier alone would fire while macOS is still dragging
    /// the window, so the snap would land and the window would immediately go
    /// back to following the cursor: a snap that undoes itself.
    private func commitIfFinished(at point: CGPoint, flags: CGEventFlags) {
        guard isOverlayVisible, let layout = snapshot else { return }
        guard !isButtonDown, !flags.contains(layout.modifier.flags) else { return }
        commit(at: point)
    }

    /// Which zones the drop will use, updated on every event.
    ///
    /// **The overlay and the drop both go through here**, so the rectangle you
    /// are shown and the rectangle the window is given cannot come apart. That
    /// is not caution for its own sake: the whole point of the gesture is that
    /// the selection is built up out of sight of any single event, and a second
    /// copy of "which zones are chosen" would be a second chance to build it
    /// differently.
    private func selection(for layout: Layout,
                           at point: CGPoint,
                           on screen: NSScreen,
                           flags: CGEventFlags) -> Set<Int> {
        let under = layout.zoneIndex(under: point, in: screen.cgVisibleFrame)

        guard let span = layout.span, flags.contains(span.flags) else {
            gathered = []
            return under.map { [$0] } ?? []
        }
        if let under { gathered.insert(under) }
        return gathered
    }

    private func describe(_ p: CGPoint) -> String {
        "(\(Int(p.x)), \(Int(p.y)))"
    }

    /// When the last actual mouse movement arrived.
    ///
    /// Together with the button's physical state it answers the one question the
    /// log could not: whether the `leftMouseUp` that ended a gesture came from a
    /// finger coming off the button, or from somewhere else. A release follows
    /// the last movement by a few tens of milliseconds; anything that ends a
    /// drag on its own leaves a much longer silence behind it.
    private var lastMovedAt: DispatchTime?

    /// When the button went down, so the drop can say how long the whole gesture
    /// lasted. A third of a second and four seconds are very different gestures
    /// and used to look the same.
    private var pressedAt: DispatchTime?

    /// When the zones went up, so that a hide can say how long they lasted.
    ///
    /// A tenth of a second and four seconds are the same line in the log
    /// otherwise, and they are not the same event: one is a finger, the other is
    /// a decision.
    private var shownAt: DispatchTime?

    private static func elapsed(since start: DispatchTime?) -> String {
        guard let start else { return "an unknown time" }
        let ms = (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        return ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    /// Which modifiers were actually down, named the way the file names them.
    private static func describe(_ flags: CGEventFlags) -> String {
        let held = Modifier.allCases.filter { flags.contains($0.flags) }
        guard !held.isEmpty else { return "no modifier held" }
        return "still held: " + held.map { "\($0.symbol) \($0.rawValue)" }.joined(separator: " ")
    }

    /// Whether it was the mouse or the keyboard that brought the news. The
    /// keyboard only started being listened to when spanning arrived, so this is
    /// the line that tells a slip apart from a deliberate release.
    private static func describe(type: CGEventType) -> String {
        switch type {
        case .flagsChanged: return "a key"
        case .leftMouseDragged: return "the mouse moving"
        case .leftMouseUp: return "the button coming up"
        default: return "\(type.rawValue)"
        }
    }

    /// Puts the window where the zones said it would go.
    ///
    /// The selection is **not** recomputed here. It is whatever was last drawn,
    /// because the event that gets us here is the modifier coming up and by then
    /// the modifier is not held — recomputing would clear any gathered span and
    /// answer with the single zone under the cursor, which is not what the user
    /// was looking at when they let go.
    private func commit(at point: CGPoint) {
        defer { forgetTheDrag() }

        Log.write("commit: after \(DragMonitor.elapsed(since: shownAt)) of choosing"
                  + " (\(DragMonitor.elapsed(since: pressedAt)) since the button went down)")

        guard let layout = snapshot else {
            // Unreachable: the snapshot is taken before the zones can appear.
            // It logs anyway, because a silent `return` on the path that moves
            // somebody's window is the kind of thing that costs an afternoon the
            // day it does happen.
            Log.write("commit: the zones were up with no layout behind them")
            return
        }
        guard let window = draggedWindow else {
            Log.write("commit: there was a zone but no window to move")
            return
        }
        guard let area = selectionArea, let target = layout.union(of: selected) else {
            Log.write("commit: nothing was selected — nothing snapped")
            return
        }

        // The same call the overlay drew a moment ago, which is the point: the
        // window lands exactly on the rectangle that was highlighted.
        let frame = layout.frame(of: target, in: area)
        Log.write("commit: snapping into \"\(target.name)\" \(frame)")
        // The usable area goes with it, because an app that refuses to shrink
        // leaves a window wider than the zone, and a zone against the right-hand
        // edge then puts the overhang under the bezel.
        window.setFrame(frame, inside: area)
    }

    /// Ends the gesture with nothing moved.
    ///
    /// This is the only way out now. Letting go of the modifier used to be it,
    /// and letting go of the modifier is what commits.
    private func abandon(_ why: String) {
        Log.write("commit: abandoned after \(DragMonitor.elapsed(since: shownAt)) — \(why)")
        forgetTheDrag()
    }
}
