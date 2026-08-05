import AppKit

// The disk image's window, drawn rather than exported, so it lives in the repo
// as the twenty lines that describe it instead of as a binary nobody can edit.
//
// The motif is the product: three columns and a window landing in one of them.
let W: CGFloat = 660, H: CGFloat = 420

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let px = Int(W * scale), py = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // No scaleBy: a context made from a rep whose `size` is in points already
    // maps those points onto the rep's pixels. Scaling again draws it twice as
    // large and crops it, which is exactly what the first version did.

    // A very dark ground, a shade off black so the app icon's own shadow reads.
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // The three columns, barely there: the layout this app is for.
    let inset: CGFloat = 46, top: CGFloat = 92, bottom: CGFloat = 46
    let usable = W - inset * 2
    let gap: CGFloat = 10
    let widths: [CGFloat] = [0.25, 0.5, 0.25]
    var x = inset
    for (i, fraction) in widths.enumerated() {
        let w = usable * fraction - gap
        let r = NSRect(x: x, y: bottom, width: w, height: H - top - bottom)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(i == 2 ? 0.07 : 0.035).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(i == 2 ? 0.16 : 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
        x += usable * fraction + gap / 2
    }

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight,
              _ alpha: CGFloat, centreY: CGFloat, tracking: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .kern: tracking,
        ]
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        a.draw(at: NSPoint(x: (W - sz.width) / 2, y: centreY - sz.height / 2))
    }

    text("ZONAS", 15, .semibold, 0.55, centreY: H - 40, tracking: 4.5)
    text("Drag it into Applications", 13, .regular, 0.38, centreY: H - 65)

    // The arrow, from where the app sits to where it is going.
    let y: CGFloat = 214
    let from: CGFloat = 224, to: CGFloat = 436
    NSColor.white.withAlphaComponent(0.30).setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: from, y: y))
    shaft.line(to: NSPoint(x: to - 12, y: y))
    shaft.lineWidth = 2
    shaft.lineCapStyle = .round
    let dashes: [CGFloat] = [7, 7]
    shaft.setLineDash(dashes, count: 2, phase: 0)
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to - 14, y: y + 7))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 14, y: y - 7))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// One TIFF carrying both resolutions: Finder picks the right one, and a 1x-only
// background is visibly soft on every Mac sold in the last decade.
let image = NSImage(size: NSSize(width: W, height: H))
image.addRepresentation(draw(scale: 1))
image.addRepresentation(draw(scale: 2))
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: URL(fileURLWithPath: "background.tiff"))
print("wrote background.tiff (\(Int(W))x\(Int(H)) points, 1x and 2x)")
