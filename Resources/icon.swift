import AppKit

// The app icon, drawn rather than exported, for the same reason the disk image's
// background is: it lives in the repository as the code that describes it, so a
// colour can be changed by editing a line instead of by finding whoever has the
// original document.
//
// It replaces an icon that was very dark — a slate square with three slightly
// darker rectangles in it, which at Dock size read as a grey blob. The motif is
// unchanged because the motif is the product: three zones at 25 / 50 / 25, the
// layout the app ships with and the one the menu bar glyph already draws.
//
//   swiftc -O icon.swift -o /tmp/iconmake && /tmp/iconmake
//
// writes Zonas.icns beside itself.

let canvas: CGFloat = 1024

/// Apple's grid for a macOS app icon: the shape occupies 824 of 1024 points,
/// centred, with a continuous-curvature corner. The margin is not optional —
/// an icon drawn edge to edge looks oversized next to every other icon in the
/// Dock.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func drawIcon(into ctx: CGContext) {
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A soft shadow under the plate, which is what makes it sit on the desktop
    // rather than float above it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    // The gradient. Bright, and warm at the bottom rather than a flat blue: the
    // old icon's problem was not only that it was dark but that it was one
    // colour, so nothing in it caught the light.
    ctx.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.32, green: 0.62, blue: 1.00, alpha: 1),   // sky
        NSColor(srgbRed: 0.35, green: 0.40, blue: 0.95, alpha: 1),   // indigo
        NSColor(srgbRed: 0.60, green: 0.32, blue: 0.92, alpha: 1),   // violet
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
    gradient.draw(in: plate, angle: -60)

    // A highlight along the top edge. Every macOS icon has one; without it the
    // plate looks printed on.
    let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.30),
                           ending: NSColor.white.withAlphaComponent(0.0))!
    sheen.draw(in: CGRect(x: plate.minX, y: plate.midY, width: plate.width,
                          height: plate.height / 2), angle: -90)
    ctx.restoreGState()

    // The three zones, in the proportions the app ships with.
    let inset: CGFloat = 132
    let field = plate.insetBy(dx: inset, dy: inset)
    let gap: CGFloat = 26
    let fractions: [CGFloat] = [0.25, 0.5, 0.25]
    // The middle one is the one you are working in — the same reason the
    // built-in layout is 25 / 50 / 25 and not three equal columns.
    let alphas: [CGFloat] = [0.62, 1.0, 0.62]

    var x = field.minX
    for (i, fraction) in fractions.enumerated() {
        let w = field.width * fraction - gap * CGFloat(fractions.count - 1) / CGFloat(fractions.count)
        let r = CGRect(x: x, y: field.minY, width: w, height: field.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34)
        NSColor.white.withAlphaComponent(alphas[i]).setFill()
        path.fill()
        x += w + gap
    }
}

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(into: NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The sizes `iconutil` expects, by the names it expects.
let wanted: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = here.appendingPathComponent("Zonas.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

for (name, size) in wanted {
    let rep = render(size)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: set.appendingPathComponent("\(name).png"))
}
print("wrote \(set.path) — now: iconutil -c icns Zonas.iconset")
