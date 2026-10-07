import AppKit
import CoreGraphics

/// An explicit diagnostic overlay. The controller decides when it is allowed
/// to appear; this surface never receives input or activates the application.
final class GazeScreenMarker {
    private var panel: GazeMarkerPanel?

    var windowID: CGWindowID? {
        guard let number = panel?.windowNumber, number > 0, number <= Int(CGWindowID.max) else { return nil }
        return CGWindowID(number)
    }

    func show(snapshot: GazeMonitorView.Snapshot, on screen: NSScreen) {
        let panel: GazeMarkerPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = GazeMarkerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = GazeMarkerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            self.panel = panel
        }
        panel.setFrame(screen.frame, display: false)
        (panel.contentView as? GazeMarkerView)?.snapshot = snapshot
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }
}

private final class GazeMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GazeMarkerView: NSView {
    var snapshot = GazeMonitorView.Snapshot() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The controls carry the accessible state. A changing full-screen
        // image should not become another navigation stop over every app.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill(); dirtyRect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(rect: bounds).addClip()

        if let id = snapshot.candidateID, let window = snapshot.windows.first(where: { $0.id == id }),
           let display = snapshot.displayBounds, finite(display), display.width > 0, display.height > 0,
           finite(window.bounds), window.bounds.width > 0, window.bounds.height > 0 {
            let rect = CGRect(x: (window.bounds.minX - display.minX) / display.width * bounds.width,
                              y: (window.bounds.minY - display.minY) / display.height * bounds.height,
                              width: window.bounds.width / display.width * bounds.width,
                              height: window.bounds.height / display.height * bounds.height)
            // Stroke the original rectangle through the display clip. Turning
            // its intersection into a new rectangle invents a window edge.
            let path = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            NSColor.systemMint.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3; path.stroke()
        }

        if let point = snapshot.stablePoint ?? snapshot.estimate, Gaze.valid(point),
           let radius = snapshot.errorRadius, radius.width.isFinite, radius.height.isFinite,
           radius.width >= 0, radius.height >= 0 {
            let centre = mapped(point)
            let rect = CGRect(x: centre.x - radius.width * bounds.width,
                              y: centre.y - radius.height * bounds.height,
                              width: 2 * radius.width * bounds.width,
                              height: 2 * radius.height * bounds.height)
            let path = NSBezierPath(rect: rect)
            NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1.5
            path.setLineDash([7, 5], count: 2, phase: 0); path.stroke()
        }

        if let point = snapshot.estimate, Gaze.valid(point) {
            let centre = mapped(point)
            let path = NSBezierPath(ovalIn: CGRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22))
            NSColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 5; path.stroke()
            NSColor.systemOrange.setStroke(); path.lineWidth = 3; path.stroke()
        }
        if let point = snapshot.stablePoint, Gaze.valid(point) {
            let centre = mapped(point)
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: centre.x - 16, y: centre.y))
            cross.line(to: CGPoint(x: centre.x + 16, y: centre.y))
            cross.move(to: CGPoint(x: centre.x, y: centre.y - 16))
            cross.line(to: CGPoint(x: centre.x, y: centre.y + 16))
            NSColor.black.withAlphaComponent(0.45).setStroke(); cross.lineWidth = 5; cross.stroke()
            NSColor.systemMint.setStroke(); cross.lineWidth = 2.5; cross.stroke()
            NSColor.systemMint.setFill()
            NSBezierPath(ovalIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)).fill()
        }
        drawStatusBadge()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawStatusBadge() {
        guard !snapshot.headline.isEmpty, bounds.width > 48 else { return }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let available = min(520, bounds.width - 32)
        let width = min(available, (snapshot.headline as NSString).size(withAttributes: [.font: font]).width + 28)
        let rect = CGRect(x: bounds.midX - width / 2, y: 32, width: width, height: 32)
        NSColor(calibratedWhite: 0.06, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (snapshot.headline as NSString).draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 7,
                                                       width: rect.width - 28, height: 18),
                                             withAttributes: [.font: font, .foregroundColor: NSColor.white,
                                                              .paragraphStyle: paragraph])
    }

    private func mapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
    }

    private func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
