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

    private var startPoint: CGPoint?
    private var draggedWindow: AXWindow?
    private var isDragging = false
    private var isOverlayVisible = false

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
        isOverlayVisible = false
        isDragging = false
        isExcluded = false
        gathered = []
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

    // MARK: - Events

    /// The tap runs on the main run loop, so this is already on the UI thread
    /// and can touch the overlay without dispatching.
    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            // Deliberately not logged. A line here is a line for every click
            // anywhere on the machine, which buries the file — the same reason
            // `mouseDragged` is not logged. `pressedAt` gives the drop what that
            // line was wanted for, which is how long the gesture lasted.
            pressedAt = DispatchTime.now()
            startPoint = event.location
            draggedWindow = nil
            isDragging = false

        case .leftMouseDragged:
            lastMovedAt = DispatchTime.now()
            handleDrag(event)

        case .leftMouseUp:
            handleDrop(event)

        // A modifier moved while the button is down. `event.location` is the
        // cursor's current position for any event type, so this is the same work
        // a drag event would have done — which is the point: pressing the
        // modifier and moving the mouse are two ways of changing the same
        // answer, and only one of them used to be heard.
        //
        // **A key can bring the zones up but never take them down**, and the
        // asymmetry is deliberate. Showing has to be instant because the user is
        // waiting to see it. Hiding does not: a modifier that comes up while the
        // hand is still is at least as likely to be a finger on its way to the
        // second key as it is to be somebody changing their mind, and blanking
        // the screen for the 40 ms it takes is a flicker with no information in
        // it. Whatever the release meant, the next mouse movement will act on
        // it — and if there is no next movement, the drop below reads the keys
        // itself. Measured: a 40 ms gap posted between two drag events used to
        // hide the zones and bring them straight back.
        case .flagsChanged:
            if isDragging { handleDrag(event) }

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

        if !isDragging {
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
        if let layout = snapshot, !isExcluded, event.flags.contains(layout.modifier.flags) {
            guard let screen = NSScreen.containing(cgPoint: current) else { return }
            if !isOverlayVisible {
                shownAt = DispatchTime.now()
                Log.write("overlay: showing zones of \"\(layout.name)\"")
            }
            overlay.show(layout, selecting: selection(for: layout, at: current, on: screen,
                                                     flags: event.flags),
                         on: screen)
            isOverlayVisible = true
        } else if isOverlayVisible, event.type != .flagsChanged {
            // Letting go of the modifier before the mouse button cancels the
            // snap, on purpose — it is how you back out of a drag you did not
            // mean to make. It used to do it without a word, so from the log a
            // cancelled drag and a broken drop looked exactly the same: an
            // overlay that appeared and no drop after it.
            //
            // It now also says what it saw and how long the overlay had been up.
            // "The modifier was released" is a conclusion, and the two things it
            // could be hiding are a person changing their mind and a key
            // bouncing for forty milliseconds on the way to another one — which
            // look identical in the old wording and want opposite fixes.
            Log.write("overlay: hidden after \(DragMonitor.elapsed(since: shownAt))"
                      + ", the modifier was released"
                      + " — nothing will snap (\(DragMonitor.describe(event.flags))"
                      + ", from \(DragMonitor.describe(type: event.type)))")
            gathered = []
            overlay.hide()
            isOverlayVisible = false
        }
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

    private func handleDrop(_ event: CGEvent) {
        defer { forgetTheDrag() }

        guard isOverlayVisible else { return }

        // Who ended the gesture, and where the event came from.
        //
        // **`.hidSystemState` and not `.combinedSessionState`**: the combined
        // state counts events other processes have posted as though a finger had
        // done it, so it answers "up" for a synthesised release just as happily
        // as for a real one — which is the exact distinction this was written to
        // make, and the first version of this line got it wrong.
        //
        // `eventSourceUnixProcessID` names the posting process when there is
        // one — but **zero does not mean "the hardware"**, which is what this
        // comment used to claim: the window server's own synthesised events
        // carry zero too. `eventSourceStateID` is the one that separates them,
        // answering 1 for a real HID event. Both are printed, because a claim
        // this line cannot support is worse than no line.
        //
        // The witness that cannot be faked by any process is the window server's
        // own log, which records the trackpad's press and release decisions:
        //
        //     log show --last 5m --info --debug --predicate \
        //       'subsystem == "com.apple.Multitouch"'
        //
        // A `Button event(mask=0) ... from HostAlgs-Button` with `Touching=0`
        // beside it is a finger leaving the pad. That is what settled this.
        //
        // It earned its place answering "Zonas cancels my drag after a second":
        // every release turned out to come from the hardware, ten to sixteen
        // milliseconds after the last pointer movement — a finger leaving the
        // trackpad mid-swipe, on a Mac with tap-to-click, drag lock and
        // three-finger drag all switched off. Nothing was cancelling anything;
        // the drag was ending because the button was. No line in the log could
        // have said that before, and the wrong answer was two hours away.
        //
        // It sits **after** the guard above on purpose. Before it, every stray
        // click anywhere on the machine wrote three lines into a log whose whole
        // discipline is that it records state transitions rather than events.
        let physicallyDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let source = event.getIntegerValueField(.eventSourceUnixProcessID)
        let poster = NSRunningApplication(processIdentifier: pid_t(source))?.localizedName ?? "unknown"
        let stateID = event.getIntegerValueField(.eventSourceStateID)
        let origin = source == 0
            ? (stateID == 1 ? "the hardware" : "pid 0, source state \(stateID) — NOT the hardware")
            : "pid \(source) (\(poster))"
        Log.write("drop: after \(DragMonitor.elapsed(since: pressedAt)), the button came up"
                  + " \(DragMonitor.elapsed(since: lastMovedAt)) after the last movement,"
                  + " from \(origin); the finger is physically "
                  + (physicallyDown ? "STILL ON THE BUTTON — this release was not the user's" : "off"))

        // The same layout that was drawn, not whatever is in the store now.
        //
        // Unreachable when it fails: the snapshot is taken before the overlay
        // can appear, and the overlay being up is what got us past the guard
        // above. It logs anyway, because a silent `return` in the drop path is
        // the kind of thing that costs an afternoon the day it does happen.
        guard let layout = snapshot else {
            Log.write("drop: the overlay was up with no layout behind it")
            return
        }

        // **The keys on the mouse-up decide, not the picture on the screen.**
        // Letting go of the modifier before the button is how you back out of a
        // drag, and until now that worked only because releasing it had already
        // hidden the overlay. Once a key on its own stopped being allowed to
        // hide anything — see `.flagsChanged` above — the overlay can still be
        // up at the moment of a deliberate cancel, and the cancel would snap the
        // window instead. Asking the event that ends the gesture is both the fix
        // and the more honest question: the drop is the decision, so the drop is
        // where the state that decides it should be read.
        guard event.flags.contains(layout.modifier.flags) else {
            Log.write("drop: the modifier was not held at the drop — nothing snapped")
            return
        }

        guard let window = draggedWindow else {
            Log.write("drop: there was a zone but no window to move")
            return
        }
        guard let screen = NSScreen.containing(cgPoint: event.location) else {
            Log.write("drop: the cursor didn't land on any screen")
            return
        }
        let area = screen.cgVisibleFrame
        // The same computation the overlay was drawn from, not a fresh one: with
        // the span key held this is several zones gathered over the length of the
        // gesture, and asking "what is under the cursor" again here would throw
        // all of them away at the last moment.
        let chosen = selection(for: layout, at: event.location, on: screen, flags: event.flags)
        guard let target = layout.union(of: chosen) else {
            Log.write("drop: the cursor didn't land inside any zone")
            return
        }

        // The same call the overlay drew a moment ago, which is the point: the
        // window lands exactly on the rectangle that was highlighted.
        let frame = layout.frame(of: target, in: area)
        Log.write("drop: snapping into \"\(target.name)\" \(frame)")
        // The usable area goes with it, because an app that refuses to shrink
        // leaves a window wider than the zone, and a zone against the right-hand
        // edge then puts the overhang under the bezel.
        window.setFrame(frame, inside: area)
    }
}
