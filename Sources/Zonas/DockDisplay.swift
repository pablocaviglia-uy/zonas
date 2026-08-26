import AppKit

/// Which screen the Dock is on — which is the screen the ⌘Tab switcher opens
/// on. `Switcher` says why that is the question and what was measured to
/// establish it; this is the half that talks to the system.
///
/// Nothing here is private API. The Dock's own window carries the answer, and
/// it carries it while the Dock is hidden: an auto-hidden Dock still has its
/// window, parked off the bottom of the screen it belongs to, and
/// `CGWindowListCreateDescriptionFromArray` will describe it.
enum DockDisplay {

    // MARK: - Reading it

    /// The Dock's window, cached by id, and the process that owns it.
    ///
    /// Finding the window means walking every window on the machine —
    /// `CGWindowListCopyWindowInfo(.optionAll, …)`, 331 of them here and 3.7 ms
    /// — and this is asked on every ⌘. Describing one known window instead costs
    /// 261 µs, and the description carries the owner and the level, so a stale
    /// id is caught rather than believed: if the Dock restarts, the read comes
    /// back as somebody else's window or as nothing, and the search runs again.
    ///
    /// The lock is not decoration. `current` is read on the main thread to draw
    /// the menu and to decide whether a correction is owed, and `move` runs the
    /// gesture on a queue of its own so the event tap's callback can return.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedWindow: CGWindowID?
    nonisolated(unsafe) private static var cachedDock: pid_t?
    nonisolated(unsafe) private static var complained = false

    /// The Dock's process id, by bundle identifier.
    ///
    /// **Not by name**, and that is the whole reason this function exists rather
    /// than a string comparison. `kCGWindowOwnerName` is the *localized*
    /// application name — measured with a bundle whose `CFBundleName` was
    /// "ZonasProbeRaw" and which came back as its localized name under forced
    /// languages — so `owner == "Dock"` is a feature that works in English and
    /// stops working in Chinese. A bundle identifier is not translated.
    private static func dockPID() -> pid_t? {
        lock.lock()
        let known = cachedDock
        lock.unlock()
        if let known, kill(known, 0) == 0 { return known }

        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        lock.lock()
        cachedDock = dock.processIdentifier
        lock.unlock()
        return dock.processIdentifier
    }

    /// Where the Dock is, in CG coordinates. Safe to call from any thread.
    ///
    /// The Dock's window covers the whole screen it is on — 5120×1440 for the
    /// screen at the origin — so this is the screen's frame, not the strip of
    /// icons. It is the same window whether the Dock is shown, auto-hidden, or
    /// drawing the ⌘Tab switcher: measured, there is never more than one.
    static func bounds() -> CGRect? {
        lock.lock()
        let known = cachedWindow
        lock.unlock()

        if let known, let rect = describe(known) { return found(rect) }

        guard let found = search() else {
            // Rule 9, said once. This is called from a poll every 5 ms, so an
            // unconditional line here writes two hundred a second.
            if !complained {
                complained = true
                Log.write("switcher: the Dock has no window — cannot tell which screen "
                          + "the switcher opens on")
            }
            return nil
        }
        lock.lock()
        cachedWindow = found.id
        lock.unlock()
        return self.found(found.rect)
    }

    private static func found(_ rect: CGRect) -> CGRect {
        complained = false
        return rect
    }

    /// The screen the Dock is on. Main thread — it touches `NSScreen`.
    static var current: NSScreen? {
        guard let bounds = bounds() else { return nil }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return NSScreen.screens.first { $0.cgFrame.contains(centre) }
    }

    private static func describe(_ id: CGWindowID) -> CGRect? {
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        return ids.withUnsafeMutableBufferPointer { buffer -> CGRect? in
            guard let array = CFArrayCreate(nil, buffer.baseAddress, 1, nil),
                  let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
                  let window = list.first else { return nil }
            return rect(of: window)
        }
    }

    private static func search() -> (id: CGWindowID, rect: CGRect)? {
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in all {
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let rect = rect(of: window) else { continue }
            return (id, rect)
        }
        return nil
    }

    /// The Dock owns several windows and only one of them is the Dock itself.
    ///
    /// **Identified by owning process and window level, and deliberately not by
    /// its title.** The obvious test is `kCGWindowName == "Dock"`, it reads
    /// perfectly from a binary launched in a terminal, and it identifies nothing
    /// at all in the shipped app: macOS redacts window *titles* from any process
    /// without the Screen Recording permission, which Zonas does not have and
    /// does not want. Measured, same machine, minutes apart — from this shell,
    /// 336 of 337 windows carry a name and the Dock's is "Dock"; from a
    /// Developer-ID-signed `.app` launched with `open`, 12 of 331 carry a name
    /// and the Dock's window has none. `kCGWindowOwnerPID`, `kCGWindowLayer` and
    /// the bounds all survive; only the title is stripped. Left as a title
    /// comparison, this whole feature would have been inert for every user who
    /// is not running it out of a terminal, and every test of it here would have
    /// passed.
    ///
    /// The other Dock-owned windows are the wallpapers, one per screen, and they
    /// sit at `.desktopWindow` rather than `.dockWindow` — so the level tells
    /// them apart without needing a name either.
    private static func rect(of window: [String: Any]) -> CGRect? {
        guard let dock = dockPID(),
              window[kCGWindowOwnerPID as String] as? pid_t == dock,
              window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)),
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Naming screens

    /// The UUID a screen is known by. Survives being unplugged and plugged back
    /// in, which a `CGDirectDisplayID` does not.
    static func uuid(of screen: NSScreen) -> String? {
        guard let id = screen.displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(_ uuid: String) -> NSScreen? {
        NSScreen.screens.first { DockDisplay.uuid(of: $0) == uuid }
    }

    // MARK: - Moving it

    /// The mark Zonas puts on the pointer movement it makes up.
    ///
    /// The gesture below goes out through the session event tap, which is the
    /// same tap `DragMonitor` listens on — so the app is about to be told the
    /// pointer travelled forty points to the bottom of a screen and back, in the
    /// middle of whatever the user was doing. `DragMonitor` only listens to
    /// `.mouseMoved` while a gesture is live and this only runs while one is
    /// not, so the two should never meet; "should never" is exactly the kind of
    /// claim that stops being true when somebody adds an event type, and the
    /// mark costs one comparison.
    ///
    /// `eventSourceUserData` survives the round trip through a tap intact —
    /// measured, because there was no reason to assume it would.
    static let ourOwnGesture: Int64 = 0x5A_4F_4E_41_53   // "ZONAS"

    /// The gesture runs here, off the main thread.
    ///
    /// Posting the events is quick — 1.5 ms — but *waiting for the Dock* is up
    /// to a second, and the caller is an event tap callback on the main run
    /// loop. A callback that takes a second is a callback macOS stops calling
    /// altogether: `DragMonitor.revive` exists because of that, and it would be
    /// the drag gesture that paid for it, not this.
    private static let queue = DispatchQueue(label: "uy.com.fcstudio.zonas.dock")

    /// Puts the Dock, and so the switcher, on `screen`.
    ///
    /// Call on the main thread: it reads `NSScreen`. `finished` is called back
    /// on the main thread with whether the Dock actually went — Rule 8's shape,
    /// and not a formality here. Two of the three things tried before this one
    /// reported success and did nothing.
    static func move(to screen: NSScreen, then finished: ((Bool) -> Void)? = nil) {
        // Every way out of this method answers on the main thread and never
        // before it has returned. A completion that is sometimes synchronous and
        // sometimes not is a caller writing `moving = true` after being told the
        // move already failed, and then never writing `false` again.
        func answer(_ landed: Bool) { DispatchQueue.main.async { finished?(landed) } }

        let edge = Switcher.Edge.current
        guard edge == .bottom else {
            // Rule 9. This one refuses on a machine that looks perfectly
            // ordinary, and the reason is not something anybody would guess from
            // the outside — see `Switcher.Edge`.
            Log.write("switcher: the Dock is on the \(edge.rawValue) and only a Dock at the "
                      + "bottom can be moved between screens — leaving it alone")
            answer(false)
            return
        }

        let frame = screen.cgFrame
        let name = screen.localizedName
        let path = Switcher.approach(intoBottomOf: frame)
        guard !path.isEmpty else {
            Log.write("switcher: \(name) is too short to walk the pointer into — leaving it alone")
            answer(false)
            return
        }

        queue.async {
            let cursor = CGEvent(source: nil)?.location
            push(along: path)
            // Straight back, before waiting for the answer. Every millisecond
            // the pointer spends where the user did not put it is a millisecond
            // they can see, and the Dock has already been told what it needs to
            // know.
            if let cursor { CGWarpMouseCursorPosition(cursor) }

            let landed = waitForTheDock(toReach: frame)
            Log.write(landed
                      ? "switcher: moved to \(name)"
                      : "switcher: pushed the pointer at \(name)'s Dock edge and the Dock stayed put")
            answer(landed)
        }
    }

    /// One `.mouseMoved` event per step, walked into the edge.
    ///
    /// The deltas are set as well as the position. A `.mouseMoved` event with no
    /// delta is a teleport, and a teleport is exactly what does not work — see
    /// `Switcher`.
    ///
    /// **No pause between the events, and that is measured rather than
    /// careless.** Posting them back to back works 12 times out of 12 and puts
    /// the pointer back in 1.5 ms; spacing them 6 ms apart also works, and costs
    /// 37 ms. The difference matters for one reason: a menu or the switcher
    /// itself, once open, owns the mouse and swallows this whole walk. Thirty-
    /// seven milliseconds is inside the window where somebody who presses ⌘Tab
    /// quickly opens the switcher on top of the correction meant for it. One and
    /// a half is not.
    private static func push(along path: [CGPoint]) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard var previous = path.first else { return }
        // The pointer is put at the start of the run rather than walked there
        // from wherever it was: the walk that matters is the last forty points.
        // The first point is that standing start and is **not** posted — posting
        // it would be one event carrying a delta of zero, and the Dock counts
        // movement, so it would shorten the run by a step.
        CGWarpMouseCursorPosition(previous)

        for point in path.dropFirst() {
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - previous.x))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - previous.y))
            event.setIntegerValueField(.eventSourceUserData, value: ourOwnGesture)
            event.post(tap: .cghidEventTap)
            previous = point
        }
    }

    /// The Dock settles about 200 ms after the push, so this watches for it
    /// rather than sleeping a fixed amount and hoping.
    private static func waitForTheDock(toReach frame: CGRect) -> Bool {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if let bounds = bounds(), bounds.origin == frame.origin { return true }
            usleep(5_000)
        }
        return false
    }
}
