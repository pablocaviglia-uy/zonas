import AppKit
import ApplicationServices

/// Minimal wrapper over the Accessibility API for reading and moving another
/// application's window.
///
/// Everything in here requires the user to have granted Accessibility
/// permission. Without it the calls don't fail loudly: they return an error and
/// the app simply looks like it isn't doing anything, which is the most
/// confusing way to break.
struct AXWindow {
    let element: AXUIElement

    /// How long an application that has stopped answering gets before Zonas
    /// gives up on it.
    ///
    /// This matters because of *where* the lookup below runs: inside the event
    /// tap's callback, on the main run loop. A callback that takes too long has
    /// its tap disabled by the system, and `DragMonitor.revive` exists because
    /// that happens. The default is not a safe number here — measured by sending
    /// a live application `SIGSTOP` and reading one attribute off one of its
    /// windows, **a single call takes 1503 ms** before it gives up, and the
    /// lookup below makes several.
    ///
    /// 250 ms is five times the slowest healthy walk ever measured on this
    /// machine (48 ms, over 378 samples swept across the whole screen; median
    /// 0.8 ms, p99 4.1 ms), so an app has to be genuinely stuck to reach it.
    private static let messagingTimeout: Float = 0.25

    /// The system-wide element every lookup starts from, and the only place the
    /// timeout is set.
    ///
    /// It is one shared element rather than a fresh one per drag because
    /// `AXUIElementSetMessagingTimeout` on the system-wide object is what sets
    /// the default for **every element this process creates afterwards** — which
    /// is the only way to cover the elements the walk discovers as it goes,
    /// since there is nowhere to configure those before they exist. Verified,
    /// against a stopped process: with the timeout set here and nowhere else, a
    /// read off an application element and a read off a window element both came
    /// back at 252 ms instead of 1503.
    private static let system: AXUIElement = {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        return system
    }()

    /// Finds the window sitting under a point on screen (CG coordinates).
    ///
    /// `AXUIElementCopyElementAtPosition` returns the **most specific** element
    /// under the cursor: a button, a cell, a text field. Getting from there to
    /// the window takes two mechanisms, because neither one covers everything.
    ///
    /// **First, ask the element which window it is in.** `kAXWindowAttribute` is
    /// a single call and it is exact. Measured against the walk below at 912
    /// points of a covered screen, and against the deepest leaves reachable in
    /// ten running applications — Chrome, Firefox, Finder, iTerm2, OrbStack,
    /// Android Studio, Teams, WhatsApp, Claude and the Android emulator — it
    /// named the same window every single time it answered, at 0.03 ms against
    /// the walk's 1.24 ms.
    ///
    /// **Then walk the parent chain**, because three things answer `nil`: a
    /// window, which is not inside a window; an element inside a sheet; and a
    /// toolkit that never implemented the attribute, which is the Android
    /// emulator's Qt windows here — six leaves, attribute `nil` on all six, walk
    /// finds the window on all six.
    ///
    /// **The walk ends at the application, not at a hop count.** Every chain is
    /// terminated by an element whose role is `AXApplication`, so reaching one
    /// means the point was over something with no window above it — a menu bar,
    /// the desktop. The hop limit is now only a backstop against cyclic parents,
    /// which are out there.
    ///
    /// It used to be the terminator, at 12, and that was not a margin — it was
    /// losing whole applications. Chromium builds its title bar and its chrome
    /// out of the same nested DOM as the page, so the chain is as deep at the
    /// top of the window as anywhere else. Claude Desktop's is **32 hops**, and
    /// with its window filling the screen the shipped code identified a window
    /// at **0 of 1995 sampled points**: hold the modifier, drag it anywhere at
    /// all, and the zones would light up and nothing would ever move. Teams has
    /// leaves 23 deep by the same measurement, though it could not be raised to
    /// the front to sweep. Chrome, Firefox, Android Studio and iTerm2 all resolve
    /// under 10 hops, which is why this survived being used every day.
    ///
    /// **A failed read ends the walk.** It used to fall through to the parent,
    /// which against an app that has stopped answering means paying the timeout
    /// again at every level.
    static func at(cgPoint point: CGPoint) -> Lookup {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,
                                               Float(point.x),
                                               Float(point.y),
                                               &found) == .success,
              let leaf = found else { return .nothing("there is nothing there") }

        guard let element = window(containing: leaf) else {
            return .nothing("there is no window there")
        }
        let window = AXWindow(element: element)
        if let refusal = window.refusal { return .nothing(refusal) }
        return .window(window)
    }

    /// What was under the point: a window Zonas will move, or a sentence saying
    /// why not.
    ///
    /// The reason is the whole of why this is not an `Optional`. Everything in
    /// this stage is invisible when it goes wrong — you drag, and the window
    /// does not move, and every cause looks identical from the outside. One line
    /// naming the actual cause is the difference between a bug report and a
    /// shrug.
    enum Lookup {
        case window(AXWindow)
        case nothing(String)
    }

    private static func window(containing leaf: AXUIElement) -> AXUIElement? {
        if let window = leaf.containingWindow { return window }

        var current = leaf
        for _ in 0 ..< 100 {
            guard let role = current.role else { return nil }
            if role == kAXWindowRole { return current }
            if role == kAXApplicationRole { return nil }
            guard let parent = current.parent else { return nil }
            current = parent
        }
        return nil
    }

    /// Why this window is not one Zonas will move, or `nil` when it will be.
    ///
    /// Three questions, asked in this order because each produces a clearer
    /// sentence than the one after it would for the same window, and because
    /// **none of them subsumes the others** — which is the thing worth knowing,
    /// since each one on its own looks sufficient until it is measured.
    var refusal: String? {
        if let subrole = element.subrole, AXWindow.isTheSystemsOwn(subrole: subrole) {
            return "\(name) is \(subrole), which belongs to the system rather than to an app"
        }

        // Full screen, and it has to be asked about by name because on a
        // full-screen window the Accessibility API lies twice over: measured on
        // a TextEdit window, `AXUIElementIsAttributeSettable` answers **yes**
        // for the size, and setting the size returns **success**, and the window
        // does not move. Only the position fails honestly, with
        // kAXErrorFailure. So the settability question below cannot stand in for
        // this one, and without it a drag onto a full-screen window would be
        // logged as a snap that worked.
        //
        // `AXFullScreen` is a string literal because there is no constant for it
        // in the public headers. It is what every window manager on macOS uses.
        if element.flag("AXFullScreen") == true {
            return "\(name) is in full screen, which cannot be moved through Accessibility"
        }

        // A window whose size is not settable used to be refused here, and that
        // was wrong for the same reason the subrole allowlist was wrong. It is a
        // good description of Notification Center's shield, its banners and
        // Teams' notification window — every non-standard window on this
        // machine reports a settable position and a size that is not — but it is
        // an equally good description of Xcode's Welcome window and the iPhone
        // Simulator, which people move around all day. `setFrame` places those
        // without resizing them instead, which is a better answer than either
        // refusing them or handing them a size they will throw away.
        //
        // The position is not asked about either. It is settable on practically
        // everything, including elements nobody would call a window, so it
        // rejects nothing and would only muddy the reason given.
        return nil
    }

    /// Whether a subrole names one of the system's own panels rather than an
    /// application's window.
    ///
    /// **The obvious rule was to accept `AXStandardWindow` and nothing else, and
    /// it was wrong.** It looked extremely well supported here: eleven
    /// applications, four of them Electron and one a JetBrains IDE — the two
    /// families this stage expected trouble from — every real window reporting
    /// `AXStandardWindow`, and every impostor naming itself something else.
    ///
    /// It does not survive contact with software that is not installed on this
    /// machine. The subrole space is open — Finder ships a window whose subrole
    /// is the string `"Quick Look"`, which is in no header — and the named
    /// subroles are used by real, draggable windows: `AXUnknown` by Steam, by
    /// Keynote in presentation mode, and by Firefox and VLC in their own
    /// non-native full screen; `AXDialog` by Xcode's Settings window and
    /// IntelliJ's Open dialog; `AXFloatingWindow` by Transmission's Inspector.
    /// A census of 119 windows collected by AeroSpace found 79 standard against
    /// 40 that were not. An allowlist of one would refuse to move every one of
    /// those, and refusing to move somebody's window is the failure this whole
    /// stage exists to prevent — a window that snaps somewhere odd is a shrug, a
    /// window that will not move is the reason a repository gets a reputation.
    ///
    /// So the rule keeps only what is unambiguous. `AXSystemDialog` and
    /// `AXSystemFloatingWindow` are the system's own dialogs and panels by
    /// Apple's definition of them; nobody drags one into a zone. Everything else
    /// is offered to the settability question above, which is what actually
    /// distinguishes a window from a panel — and which catches every impostor on
    /// this machine except one, the Android emulator's floating toolbar, that no
    /// rule worth shipping could catch without also refusing Transmission's.
    static func isTheSystemsOwn(subrole: String) -> Bool {
        subrole == kAXSystemDialogSubrole as String
            || subrole == kAXSystemFloatingWindowSubrole as String
    }

    /// The process the window belongs to, which is what every question about
    /// the *application* rather than the window has to be asked through.
    var pid: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private var runningApplication: NSRunningApplication? {
        pid.flatMap(NSRunningApplication.init(processIdentifier:))
    }

    /// How the window is referred to in the log: the app, and the title when
    /// there is one.
    ///
    /// It is built for the reader of `~/Library/Logs/Zonas.log` and nobody else.
    /// Everything this stage refuses is refused invisibly — the window simply
    /// does not move — and "a window" in that sentence would leave the reader
    /// exactly where they started.
    var name: String {
        let app = runningApplication?.localizedName ?? "an unnamed process"
        guard let title = element.title, !title.isEmpty else { return "\(app)'s window" }
        return "\(app)'s \"\(title)\""
    }

    var frame: CGRect? {
        guard let origin = element.position, let size = element.size else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Places the window into a rectangle (CG coordinates).
    ///
    /// Position and size are two separate attributes and the order matters. If
    /// the window is flush against an edge, setting the size first can make the
    /// system move it on its own and the result ends up offset. That's why it
    /// gets positioned, resized, and positioned again: the second pass absorbs
    /// that rearrangement.
    ///
    /// **The result is read back, and an app that would not shrink gets slid
    /// back onto the screen.** `setSize` returns success having applied
    /// something else entirely, and the window then hangs off the side of the
    /// zone — which for a zone against the right-hand edge means hanging off the
    /// side of the screen, with the part you were reaching for underneath the
    /// bezel.
    ///
    /// Floors measured on this machine, against the 428-point "Derecha" zone of
    /// the layout in use: Chrome will not go below 500 wide, Claude 600,
    /// WhatsApp 800, Xcode 600. Teams, Android Studio and iTerm2 take whatever
    /// they are given.
    ///
    /// **§7 calls this piece "per-app minimum sizes", and that is the wrong
    /// shape for the problem.** A number in the config file would be a second
    /// copy of something the application already knows and already enforces, out
    /// of date the first time anybody ships a new version, and there is nothing
    /// useful to do with it that cannot be done better by asking and looking at
    /// the answer. The Accessibility API has no attribute for a window's minimum
    /// size, and it could not have a reliable one: an app is free to clamp in
    /// `windowWillResize(_:to:)`, which is code, and runs after every constraint
    /// a query API could see. Measuring by trying is not a workaround here, it
    /// is the only thing that can be correct — and `differs(asked:applied:)` has
    /// been sitting next to this function since two stages ago with nothing
    /// acting on it.
    ///
    /// **A window that cannot be resized at all is placed rather than refused.**
    /// Xcode's Welcome window and the iPhone Simulator move but do not resize,
    /// and putting one where you dropped it is obviously better than declining
    /// to touch it. Refusing was what this did for one commit, and it was the
    /// wrong side of the same trade the subrole rule makes.
    @discardableResult
    func setFrame(_ rect: CGRect, inside area: CGRect) -> CGRect? {
        let resizable = element.isSettable(kAXSizeAttribute)
        if !resizable {
            Log.write("window: \(name) will not be resized, so it is only being moved")
        }

        var applied: CGRect?
        var slidBack = false
        // Every write is inside one toggle. Two would be two accessibility trees
        // torn down and rebuilt for one drop.
        withoutEnhancedUserInterface {
            element.setPosition(rect.origin)
            if resizable { element.setSize(rect.size) }
            element.setPosition(rect.origin)

            guard let got = frame else { return }
            let settled = AXWindow.nudged(got, inside: area)
            guard settled.origin != got.origin else { applied = got; return }
            element.setPosition(settled.origin)
            slidBack = true
            applied = frame ?? settled
        }

        guard let applied else { return nil }
        guard AXWindow.differs(asked: rect, applied: applied) else { return applied }

        // Three different things, and the line has to say which. The size the
        // app insisted on is the app's doing; the origin, when it is not the
        // one that was asked for, is *this function's* doing, and running the
        // two together into one sentence reads as the app having moved the
        // window somewhere odd.
        let floored = applied.width > rect.width || applied.height > rect.height
        let outcome: String
        if slidBack {
            outcome = "the app would not go below \(AXWindow.describe(applied.size))"
                + ", so it sits at \(AXWindow.describe(applied.origin)) to stay on the screen"
        } else if floored {
            outcome = "the app applied \(AXWindow.describe(applied)) and will not go below that"
        } else {
            outcome = "the app applied \(AXWindow.describe(applied))"
        }
        Log.write("window: asked for \(AXWindow.describe(rect)) — \(outcome)")
        return applied
    }

    /// A window pulled back far enough to be on the screen, and no further.
    ///
    /// **The zone's own origin is kept whenever it can be**, and the window is
    /// only slid back by however much it overhangs. That is the rule because it
    /// is the one somebody can predict: a window too wide for the right-hand
    /// zone ends up flush with the right-hand edge of the screen, which is where
    /// the zone was pointing.
    ///
    /// Centring the overflow on the zone instead was the other candidate. It
    /// gives a prettier result for a zone in the middle and a worse one at every
    /// edge — at the right-hand zone it pushes the window *further* off the
    /// screen before the clamp has to drag it back, so the clamp is doing the
    /// work either way and the centring only moves the window away from where it
    /// was dropped.
    ///
    /// A window wider than the whole usable area goes flush to the left rather
    /// than off the right: the `max` is applied last on purpose, so when the two
    /// bounds contradict each other it is the near edge that wins. Anything else
    /// puts the title bar somewhere you cannot reach it.
    static func nudged(_ frame: CGRect, inside area: CGRect) -> CGRect {
        CGRect(x: max(area.minX, min(frame.minX, area.maxX - frame.width)),
               y: max(area.minY, min(frame.minY, area.maxY - frame.height)),
               width: frame.width,
               height: frame.height)
    }

    /// The name of the attribute an assistive application sets on another
    /// application to ask it for a fuller accessibility tree.
    ///
    /// It is a string literal because it is in no public header, which is also
    /// why it is easy to have never heard of.
    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// Runs the frame writes with the application's enhanced accessibility
    /// turned off, and puts it back exactly as it was found.
    ///
    /// **With that attribute set, `kAXSizeAttribute` is ignored.** Not delayed,
    /// not animated, not clamped — ignored, while the position is applied
    /// normally and every call returns success. Measured on this machine by
    /// setting the flag the way an assistive application would and asking for a
    /// 432 × 700 rectangle:
    ///
    /// ```
    ///                    flag on          flag off
    /// Google Chrome      1728x1079        500x700   (Chrome's own floor)
    /// Microsoft Teams    1728x1084        432x700   exactly as asked
    /// WhatsApp            856x1084        800x700   (its own floor)
    /// Android Studio     1728x1084        432x700   exactly as asked
    /// Firefox            1728x1084        500x700   (its own floor)
    /// iTerm2             1728x1084        432x700   exactly as asked
    /// ```
    ///
    /// **§7 calls this an Electron and Chrome problem and that is wrong.**
    /// iTerm2 and Android Studio fail exactly as completely as Chrome does,
    /// which is what the right-hand column above is for: this is AppKit's
    /// accessibility path, not any application's quirk, and a list of affected
    /// bundle identifiers would be a list of every application there is. So
    /// there is no list, and nothing here asks who the app is.
    ///
    /// **It is only touched when it is already on.** Nothing in Zonas sets it,
    /// and it was `false` on all 49 processes running on this machine — with
    /// Zonas itself running, holding Accessibility permission, and with
    /// Hammerspoon running too. Whoever turns it on is some other assistive
    /// application on the user's machine, and the point of this is that Zonas
    /// keeps working next to them rather than silently losing the ability to
    /// resize anything.
    ///
    /// **And it is put back.** Turning it off is somebody else's setting being
    /// overridden, and leaving it off degrades whatever asked for it. Chromium
    /// is on record that the re-enable is the expensive edge — it rebuilds the
    /// accessibility tree, and "in extreme cases can result in the browser
    /// becoming non-responsive" (bug 1364487) — which is an argument for not
    /// doing this on every mouse move, and this runs once, on the drop.
    ///
    /// A failure to write it is not worth handling: some Electron builds refuse
    /// with `kAXErrorNotImplemented`, and an app that will not turn the flag off
    /// is an app that was not going to be affected by it.
    private func withoutEnhancedUserInterface(_ body: () -> Void) {
        guard let pid else { return body() }
        let application = AXUIElementCreateApplication(pid)
        guard application.flag(AXWindow.enhancedUserInterface) == true else { return body() }

        Log.write("window: \(name) has enhanced accessibility on,"
                  + " which makes the size silently ignored — turning it off for the move")
        application.setFlag(AXWindow.enhancedUserInterface, false)
        defer { application.setFlag(AXWindow.enhancedUserInterface, true) }
        body()
    }

    /// Whether what the app applied is far enough from what was asked to be
    /// worth a line in the log.
    ///
    /// The slack is there because plenty of apps round to whole points, and
    /// half a point of difference is not something anybody needs told about at
    /// the end of every single drag.
    static func differs(asked: CGRect, applied: CGRect, slack: CGFloat = 1) -> Bool {
        abs(applied.origin.x - asked.origin.x) > slack
            || abs(applied.origin.y - asked.origin.y) > slack
            || abs(applied.width - asked.width) > slack
            || abs(applied.height - asked.height) > slack
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(describe(rect.size)) at \(describe(rect.origin))"
    }

    private static func describe(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    private static func describe(_ point: CGPoint) -> String {
        "(\(Int(point.x)), \(Int(point.y)))"
    }
}

extension AXUIElement {

    fileprivate func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    fileprivate var role: String? {
        attribute(kAXRoleAttribute) as? String
    }

    fileprivate var subrole: String? {
        attribute(kAXSubroleAttribute) as? String
    }

    fileprivate var title: String? {
        attribute(kAXTitleAttribute) as? String
    }

    /// A boolean attribute, or `nil` when the element does not have one.
    ///
    /// The distinction matters for `AXFullScreen`: an element that has never
    /// heard of it and one that says `false` mean the same thing here, but only
    /// because the caller says so, not because the API blurs them.
    fileprivate func flag(_ name: String) -> Bool? {
        attribute(name) as? Bool
    }

    /// Whether the app will accept a write to this attribute.
    ///
    /// A failure to answer counts as "no". The call fails for an element that
    /// has gone away or an app that has stopped answering, and in both cases
    /// writing to it is not going to work either.
    fileprivate func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    fileprivate func relative(_ name: String) -> AXUIElement? {
        guard let value = attribute(name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    fileprivate var parent: AXUIElement? { relative(kAXParentAttribute) }

    /// The window this element is drawn in, straight from the element.
    ///
    /// `nil` does not mean "not in a window" — a window itself answers `nil`
    /// here, and so does everything inside a sheet. It means "ask another way".
    fileprivate var containingWindow: AXUIElement? { relative(kAXWindowAttribute) }

    fileprivate var position: CGPoint? {
        guard let value = attribute(kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    fileprivate var size: CGSize? {
        guard let value = attribute(kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    fileprivate func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    fileprivate func setFlag(_ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(self, name as CFString, value as CFTypeRef)
    }

    fileprivate func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }
}
