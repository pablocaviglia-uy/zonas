import AppKit

/// The translucent layer that shows the zones while a window is being dragged.
///
/// One borderless window per screen, click-through, floating above everything
/// else. It takes no part in the drag: it only draws.
final class OverlayController {

    /// One overlay window per **display**, not per `NSScreen`.
    ///
    /// See `NSScreen.displayID`: AppKit hands out fresh `NSScreen` instances on
    /// every display reconfiguration, so a dictionary keyed by one grew a new
    /// entry —and a new window— every time a monitor was plugged in, and never
    /// let go of the old ones.
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var currentDisplay: CGDirectDisplayID?

    /// What is on screen right now, so that an event that changes nothing does
    /// nothing. See `show(_:cursor:on:)`.
    private var shown: (layout: Layout, activeIndex: Int?)?

    /// Shows the zones of one layout and highlights the one under the cursor.
    ///
    /// The layout arrives as an argument rather than being read from the store,
    /// and that is the point: a drag holds one layout still from beginning to
    /// end. Reading the shared one here would let the zones you were shown and
    /// the zone you snap into come from two different versions of the file — a
    /// race with a very wide window once the file watcher is live, because the
    /// whole gesture lasts seconds and a save takes none.
    ///
    /// - Parameters:
    ///   - layout: the layout this drag is working against.
    ///   - point: cursor position in CG coordinates.
    ///   - screen: the screen the drag is happening on.
    func show(_ layout: Layout, cursor point: CGPoint, on screen: NSScreen) {
        guard let display = screen.displayID else {
            // Documented as always present. If it ever is not, saying so beats
            // drawing on a screen we cannot tell apart from another one.
            Log.write("overlay: screen without an NSScreenNumber, not drawing")
            return
        }
        if currentDisplay != display { hide() }
        currentDisplay = display

        let area = screen.cgVisibleFrame
        let activeIndex = layout.zoneIndex(under: point, in: area)

        let window = window(for: screen, display: display)
        guard let view = window.contentView as? ZoneOverlayView else { return }

        // A mouseDragged arrives dozens of times per second and almost all of
        // them land inside the same zone as the one before. Rebuilding the whole
        // array and forcing a redraw for each one is work done inside the event
        // tap callback, and a tap that takes too long is one the system turns
        // off — which is what `tapDisabledByTimeout` up in DragMonitor exists to
        // notice.
        if window.isVisible, let shown, shown.layout == layout, shown.activeIndex == activeIndex {
            return
        }
        shown = (layout, activeIndex)

        // Zones are computed in CG and then converted to view coordinates, which
        // are the window's: origin bottom-left and relative to its own frame.
        //
        // What gets drawn is `frame`, not `rect`: the frame is the rectangle the
        // window is going to be given, and the preview showing anything else is
        // the preview lying.
        let windowFrame = window.frame
        view.zones = layout.zones.enumerated().map { index, zone in
            let rectCocoa = Coords.cgToCocoa(layout.frame(of: zone, in: area))
            return ZoneOverlayView.Box(
                rect: rectCocoa.offsetBy(dx: -windowFrame.origin.x, dy: -windowFrame.origin.y),
                name: zone.name,
                // By index. Two zones with the same geometry are a thing people
                // write in a config file, and comparing rectangles would light
                // up both of them.
                isActive: index == activeIndex
            )
        }

        window.orderFrontRegardless()
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil) }
        currentDisplay = nil
        shown = nil
    }

    private func window(for screen: NSScreen, display: CGDirectDisplayID) -> NSWindow {
        if let existing = windows[display] {
            existing.setFrame(screen.visibleFrame, display: false)
            return existing
        }

        let window = NSWindow(contentRect: screen.visibleFrame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true           // the drag has to pass straight through

        // Above normal windows and also above the one being dragged, which macOS
        // raises for as long as the gesture lasts. With `.floating` the preview
        // can end up covered by the very window you are moving.
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = ZoneOverlayView(frame: NSRect(origin: .zero,
                                                           size: screen.visibleFrame.size))
        windows[display] = window
        return window
    }
}

/// Draws the zone rectangles.
final class ZoneOverlayView: NSView {

    struct Box {
        let rect: CGRect
        let name: String
        let isActive: Bool
    }

    var zones: [Box] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        for box in zones {
            // No inset here. The gap belongs to the layout —`frame(of:in:)`—
            // because the snap has to apply the very same one, and a number
            // that lives in the drawing code is a number the snap cannot see.
            let frame = box.rect
            let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)

            if box.isActive {
                NSColor.controlAccentColor.withAlphaComponent(0.32).setFill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 3
            } else {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSColor.white.withAlphaComponent(0.30).setStroke()
                path.lineWidth = 1.5
            }
            path.fill()
            path.stroke()

            drawName(box.name, in: frame, highlighted: box.isActive)
        }
    }

    private func drawName(_ name: String, in frame: CGRect, highlighted: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: highlighted ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(highlighted ? 0.95 : 0.55),
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        let size = text.size()
        text.draw(at: CGPoint(x: frame.midX - size.width / 2,
                              y: frame.midY - size.height / 2))
    }
}
