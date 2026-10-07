import AppKit
import CoreGraphics

/// A picture of the estimator's current state, without capture or window queries.
/// CG coordinates have a top-left origin; using a flipped view keeps displays
/// above or to the left of the main display from reversing the picture.
final class GazeMonitorView: NSView {
    struct Snapshot {
        var displayBounds: CGRect? = nil
        var windows: [Gaze.Window] = []
        var estimate: CGPoint? = nil
        var stablePoint: CGPoint? = nil
        var errorRadius: CGSize? = nil
        var candidateID: CGWindowID? = nil
        var windowLabels: [CGWindowID: String] = [:]
        var headline = "Live gaze monitor"
        var detail = "Start the camera and calibrate to see where your gaze is estimated."
    }

    var snapshot = Snapshot() {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 540, height: 320) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live gaze monitor")
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { drawContents() }
    }

    private func drawContents() {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let inset: CGFloat = 14
        let width = max(0, bounds.width - 2 * inset)
        text(snapshot.headline, in: CGRect(x: inset, y: 12, width: width, height: 22),
             font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
        text(snapshot.detail, in: CGRect(x: inset, y: 38, width: width, height: 38),
             font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lines: true)

        let mapArea = CGRect(x: inset, y: 82, width: width, height: max(0, bounds.height - 132))
        if let display = snapshot.displayBounds, Self.finite(display), display.width > 0, display.height > 0,
           mapArea.width > 0, mapArea.height > 0 {
            let scale = min(mapArea.width / display.width, mapArea.height / display.height)
            let map = CGRect(x: mapArea.midX - display.width * scale / 2,
                             y: mapArea.midY - display.height * scale / 2,
                             width: display.width * scale, height: display.height * scale)
            drawMap(display: display, map: map)
        } else {
            text("The selected display will appear here",
                 in: CGRect(x: mapArea.minX, y: mapArea.midY - 10, width: mapArea.width, height: 24),
                 font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, centered: true)
        }
        drawLegend(in: CGRect(x: inset, y: bounds.height - 42, width: width, height: 34))
    }

    private func drawMap(display: CGRect, map: CGRect) {
        let palette = MapPalette(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        palette.background.setFill()
        NSBezierPath(rect: map).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: map).addClip()

        // The inventory is front-to-back. Painting it backwards preserves
        // occlusion, including windows which cannot be switcher candidates.
        for (index, window) in snapshot.windows.enumerated().reversed() {
            guard Self.finite(window.bounds), window.bounds.width > 0, window.bounds.height > 0,
                  window.bounds.intersects(display) else { continue }
            let mapped = CGRect(x: map.minX + (window.bounds.minX - display.minX) / display.width * map.width,
                                y: map.minY + (window.bounds.minY - display.minY) / display.height * map.height,
                                width: window.bounds.width / display.width * map.width,
                                height: window.bounds.height / display.height * map.height)
            let candidate = window.id == snapshot.candidateID
            let path = NSBezierPath(rect: mapped)
            (candidate ? palette.candidate : palette.window).setFill()
            path.fill()
            (candidate ? NSColor.systemMint : palette.stroke).setStroke()
            path.lineWidth = candidate ? 2 : 1
            path.stroke()
            let visible = mapped.intersection(map)
            if visible.width > 52, visible.height > 22 {
                let label = CGRect(x: visible.minX + 6, y: visible.minY + 5,
                                   width: visible.width - 12, height: 14)
                let labelOnDisplay = CGRect(x: display.minX + (label.minX - map.minX) / map.width * display.width,
                                            y: display.minY + (label.minY - map.minY) / map.height * display.height,
                                            width: label.width / map.width * display.width,
                                            height: label.height / map.height * display.height)
                // A name belongs only to an exposed part of its own window.
                // Overlapped titles otherwise turn the map into a text pile.
                let covered = snapshot.windows.prefix(index).contains {
                    Self.finite($0.bounds) && $0.bounds.width > 0 && $0.bounds.height > 0
                        && $0.bounds.intersects(labelOnDisplay)
                }
                if !covered {
                    text(snapshot.windowLabels[window.id] ?? "Window \(window.id)",
                         in: label, font: .systemFont(ofSize: 10, weight: candidate ? .semibold : .regular),
                         color: palette.label)
                }
            }
        }

        // This is the calibration's measured error, not a live confidence
        // score. Clipping it to the map is only drawing; the candidate logic
        // still rejects an uncertainty box extending beyond the display.
        if let point = snapshot.stablePoint ?? snapshot.estimate, Gaze.valid(point),
           let radius = snapshot.errorRadius, radius.width.isFinite, radius.height.isFinite,
           radius.width >= 0, radius.height >= 0 {
            let centre = mapped(point, to: map)
            let box = CGRect(x: centre.x - radius.width * map.width,
                             y: centre.y - radius.height * map.height,
                             width: radius.width * map.width * 2,
                             height: radius.height * map.height * 2)
            let path = NSBezierPath(rect: box)
            NSColor.systemOrange.withAlphaComponent(0.09).setFill(); path.fill()
            NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
        }
        if let point = snapshot.estimate, Gaze.valid(point) { drawEstimate(at: mapped(point, to: map)) }
        if let point = snapshot.stablePoint, Gaze.valid(point) { drawStable(at: mapped(point, to: map)) }
        NSGraphicsContext.restoreGraphicsState()
        palette.stroke.setStroke()
        let border = NSBezierPath(rect: map); border.lineWidth = 1; border.stroke()
    }

    private struct MapPalette {
        let background: NSColor
        let window: NSColor
        let candidate: NSColor
        let stroke: NSColor
        let label: NSColor

        init(dark: Bool) {
            // Opaque map fills must cover the windows behind them in every
            // drawing context, including the live layer-backed controls.
            background = NSColor(calibratedWhite: dark ? 0.12 : 0.97, alpha: 1)
            window = NSColor(calibratedWhite: dark ? 0.20 : 0.90, alpha: 1)
            stroke = NSColor(calibratedWhite: dark ? 0.43 : 0.65, alpha: 1)
            label = NSColor(calibratedWhite: dark ? 0.90 : 0.20, alpha: 1)
            candidate = dark ? NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.30, alpha: 1)
                             : NSColor(calibratedRed: 0.73, green: 0.93, blue: 0.87, alpha: 1)
        }
    }

    private func mapped(_ point: CGPoint, to map: CGRect) -> CGPoint {
        CGPoint(x: map.minX + point.x * map.width, y: map.minY + point.y * map.height)
    }

    private func drawEstimate(at point: CGPoint) {
        NSColor.windowBackgroundColor.setFill()
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        circle.fill()
        NSColor.systemOrange.setStroke(); circle.lineWidth = 2; circle.stroke()
    }

    private func drawStable(at point: CGPoint) {
        NSColor.systemMint.setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        NSColor.systemMint.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: point.x - 9, y: point.y)); cross.line(to: CGPoint(x: point.x + 9, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - 9)); cross.line(to: CGPoint(x: point.x, y: point.y + 9))
        cross.lineWidth = 1.5; cross.stroke()
    }

    private func drawLegend(in rect: CGRect) {
        let y = rect.minY + 8
        drawEstimate(at: CGPoint(x: rect.minX + 5, y: y))
        text("Estimate", in: CGRect(x: rect.minX + 17, y: rect.minY, width: 73, height: 18),
             font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        drawStable(at: CGPoint(x: rect.minX + 103, y: y))
        text("Steady gaze", in: CGRect(x: rect.minX + 116, y: rect.minY, width: 84, height: 18),
             font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        if rect.width > 400 {
            let candidate = NSBezierPath(rect: CGRect(x: rect.minX + 214, y: rect.minY + 2, width: 11, height: 11))
            NSColor.systemMint.withAlphaComponent(0.24).setFill(); candidate.fill()
            NSColor.systemMint.setStroke(); candidate.lineWidth = 1.5; candidate.stroke()
            text("Window candidate", in: CGRect(x: rect.minX + 232, y: rect.minY, width: 114, height: 18),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        text("Dashed box: calibration error margin", in: CGRect(x: rect.minX, y: rect.minY + 18,
                                                                              width: rect.width, height: 16),
             font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        let position = snapshot.stablePoint ?? snapshot.estimate
        if let position, Gaze.valid(position), rect.width > 300 {
            text(String(format: "X %.0f%% · Y %.0f%%", position.x * 100, position.y * 100),
                 in: CGRect(x: rect.maxX - 115, y: rect.minY, width: 115, height: 18),
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                 color: .secondaryLabelColor)
        }
    }

    private func text(_ string: String, in rect: CGRect, font: NSFont, color: NSColor,
                      lines: Bool = false, centered: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lines ? .byWordWrapping : .byTruncatingTail
        paragraph.alignment = centered ? .center : .left
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (string as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                                            .paragraphStyle: paragraph])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func updateAccessibility() {
        var value = "\(snapshot.headline). \(snapshot.detail)."
        if let point = snapshot.estimate, Gaze.valid(point) {
            value += String(format: " Estimated gaze: %.0f percent across, %.0f percent down.", point.x * 100, point.y * 100)
        }
        value += snapshot.stablePoint == nil ? " Gaze is not steady." : " Gaze is steady."
        if let candidate = snapshot.candidateID {
            value += " Candidate: \(snapshot.windowLabels[candidate] ?? "Window \(candidate)")."
        } else {
            value += " No window candidate."
        }
        setAccessibilityValue(value)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
