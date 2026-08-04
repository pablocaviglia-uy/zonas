import AppKit

/// The translucent layer that shows the zones while a window is being dragged.
///
/// One borderless window per screen, click-through, floating above everything
/// else. It takes no part in the drag: it only draws.
final class OverlayController {

    private var windows: [NSScreen: NSWindow] = [:]
    private var currentScreen: NSScreen?

    /// Shows the zones of one screen and highlights the one under the cursor.
    ///
    /// - Parameters:
    ///   - point: cursor position in CG coordinates.
    ///   - screen: the screen the drag is happening on.
    func show(cursor point: CGPoint, on screen: NSScreen) {
        if currentScreen != screen { hide() }
        currentScreen = screen

        let area = screen.cgVisibleFrame
        let active = ZoneStore.shared.zone(under: point, in: area)?.rect

        let window = window(for: screen)
        guard let view = window.contentView as? ZoneOverlayView else { return }

        // Zones are computed in CG and then converted to view coordinates, which
        // are the window's: origin bottom-left and relative to its own frame.
        //
        // What gets drawn is `frame`, not `rect`: the frame is the rectangle the
        // window is going to be given, and the preview showing anything else is
        // the preview lying.
        let windowFrame = window.frame
        view.zones = ZoneStore.shared.layout.zones.map { zone in
            let rectCG = zone.rect(in: area)
            let rectCocoa = Coords.cgToCocoa(zone.frame(in: area))
            return ZoneOverlayView.Box(
                rect: rectCocoa.offsetBy(dx: -windowFrame.origin.x, dy: -windowFrame.origin.y),
                name: zone.name,
                isActive: rectCG == active
            )
        }

        window.orderFrontRegardless()
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil) }
        currentScreen = nil
    }

    private func window(for screen: NSScreen) -> NSWindow {
        if let existing = windows[screen] {
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
        windows[screen] = window
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
            // No inset here. The gap belongs to the zone —`Zone.frame(in:)`—
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
