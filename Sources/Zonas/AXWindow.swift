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
    static func at(cgPoint point: CGPoint) -> AXWindow? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,
                                               Float(point.x),
                                               Float(point.y),
                                               &found) == .success,
              let leaf = found else { return nil }

        if let window = leaf.containingWindow { return AXWindow(element: window) }

        var current = leaf
        for _ in 0 ..< 100 {
            guard let role = current.role else { return nil }
            if role == kAXWindowRole { return AXWindow(element: current) }
            if role == kAXApplicationRole { return nil }
            guard let parent = current.parent else { return nil }
            current = parent
        }
        return nil
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
    /// **The result is read back, and a difference goes in the log.** Nothing is
    /// retried and nothing is corrected — an app that enforces a minimum size is
    /// going to win, and honouring per-app minimums is a job of its own. What
    /// this buys is that the failure stops being invisible: `setSize` returns
    /// success having applied something else entirely, so until now "Xcode
    /// ignores the width" was something you could only find out by measuring the
    /// window by hand and comparing. Measured on this machine: asked for 424
    /// wide, Xcode applied 600 and said yes.
    @discardableResult
    func setFrame(_ rect: CGRect) -> CGRect? {
        element.setPosition(rect.origin)
        element.setSize(rect.size)
        element.setPosition(rect.origin)

        guard let applied = frame else { return nil }
        guard AXWindow.differs(asked: rect, applied: applied) else { return applied }

        let floored = applied.width > rect.width || applied.height > rect.height
        Log.write("window: asked for \(AXWindow.describe(rect))"
                  + " — the app applied \(AXWindow.describe(applied))"
                  + (floored ? " and will not go below that" : ""))
        return applied
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
        "\(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
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

    fileprivate func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }
}
