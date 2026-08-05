import AppKit

// The image a link preview shows — LinkedIn, WhatsApp, Slack, X, iMessage.
//
// 1200 x 630 because that is what every one of them crops to. The icon on its
// own was being used before, and it is square: the preview padded it into a wide
// frame and the result was a small icon marooned between two grey bars.
//
// Everything here is sized for a card about 300 points wide in a feed, which is
// the size it will actually be seen at. That is why there are four elements and
// not eight, and why nothing is set below 22 points.
//
//   swiftc -O og.swift -o /tmp/ogmake && (cd Resources && /tmp/ogmake)

let W: CGFloat = 1200, H: CGFloat = 630

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The site's own background, so the card and the page it opens look related.
NSColor(srgbRed: 0.051, green: 0.051, blue: 0.067, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// The three zones, faint, at the proportions the app ships with. They are the
// product and they are also the only thing keeping the card from being a
// rectangle with words on it.
let top: CGFloat = 74, bottom: CGFloat = 74, side: CGFloat = 74
let field = NSRect(x: side, y: bottom, width: W - side * 2, height: H - top - bottom)
let gap: CGFloat = 16
var x = field.minX
for (i, fraction) in [CGFloat(0.25), 0.5, 0.25].enumerated() {
    let w = field.width * fraction - gap * 2 / 3
    let r = NSRect(x: x, y: field.minY, width: w, height: field.height)
    let path = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
    NSColor.white.withAlphaComponent(i == 1 ? 0.055 : 0.028).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(i == 1 ? 0.13 : 0.07).setStroke()
    path.lineWidth = 1.5
    path.stroke()
    x += field.width * fraction + gap / 3
}

// The icon, at the size it stays legible when the whole card is 300 points wide.
if let icon = NSImage(contentsOfFile: "Zonas.icns") {
    icon.draw(in: NSRect(x: 128, y: H / 2 - 105, width: 210, height: 210))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight,
          colour: NSColor, x: CGFloat, baseline: CGFloat, tracking: CGFloat = 0) {
    let a = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: colour,
        .kern: tracking,
    ])
    a.draw(at: NSPoint(x: x, y: baseline))
}

let left: CGFloat = 392
// White rather than the site's gradient: gradient type turns to mud once a feed
// scales the card down, and legibility at 300 points is the only job here.
text("Zonas", size: 96, weight: .bold, colour: .white, x: left, baseline: 356, tracking: -2)
text("Your window layout is a file.", size: 38, weight: .regular,
     colour: NSColor(white: 1, alpha: 0.82), x: left + 4, baseline: 292)
// Short enough to sit inside the middle zone. Longer lines crossed into the
// third one and read as a mistake rather than as a layout.
text("Snap windows into zones you define",
     size: 24, weight: .regular, colour: NSColor(white: 1, alpha: 0.45), x: left + 5, baseline: 244)
text("yourself, in a plain text file.",
     size: 24, weight: .regular, colour: NSColor(white: 1, alpha: 0.45), x: left + 5, baseline: 210)

// A rule and a line of facts, which is what a stranger actually wants to know.
NSColor.white.withAlphaComponent(0.12).setFill()
NSRect(x: left + 5, y: 176, width: 400, height: 1).fill()
text("macOS 14+   ·   Free and open source",
     size: 21, weight: .medium, colour: NSColor(srgbRed: 0.62, green: 0.70, blue: 1.0, alpha: 0.95),
     x: left + 5, baseline: 138)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "../docs/og.png"))
print("wrote docs/og.png (\(Int(W))x\(Int(H)))")
