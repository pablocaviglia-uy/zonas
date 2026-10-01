import AppKit
import Testing
@testable import Zonas

@Suite("A live preview never reveals the desktop during a normal handoff")
@MainActor
struct PreviewRenderingTests {
    private let a = CGRect(x: 20, y: 20, width: 100, height: 70)
    private let b = CGRect(x: 160, y: 20, width: 100, height: 70)

    private func image(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 100, height: 70), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
    }

    private func color(_ frame: PreviewHandoff<NSImage>.Frame, at point: CGPoint,
                       effects: CGFloat = 1, spotlight: Bool = false) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 110,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        CGRect(x: 0, y: 0, width: 300, height: 110).fill(using: .copy)
        let view = RingView(frame: CGRect(x: 0, y: 0, width: 300, height: 110))
        view.show(hole: frame.bounds, picture: frame.picture, spotlight: spotlight)
        view.setEffectsOpacity(effects)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.colorAt(x: Int(point.x), y: 110 - Int(point.y))).usingColorSpace(.deviceRGB)!
    }

    private func alpha(_ frame: PreviewHandoff<NSImage>.Frame, at point: CGPoint) throws -> CGFloat {
        try color(frame, at: point).alphaComponent
    }

    @Test("The old nil-frame rendering is translucent; an actual ghost is opaque")
    func reproducesBrightnessGap() throws {
        let empty = PreviewHandoff<NSImage>.Frame(window: 1, bounds: a, picture: nil)
        let ready = PreviewHandoff<NSImage>.Frame(window: 1, bounds: a, picture: image(.white))
        let centre = CGPoint(x: a.midX, y: a.midY)
        #expect(try alpha(empty, at: centre) < 0.5)
        #expect(try alpha(ready, at: centre) > 0.99)
    }

    @Test("A delayed first frame does not open a translucent hole at the new window")
    func delayedTargetRemainsOpaque() throws {
        var handoff = PreviewHandoff<NSImage>()
        handoff.choose(window: 1, bounds: a, picture: image(.white), expectsPicture: true)
        for _ in 0..<6 {
            let choice = handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
            let waiting = try #require(choice)
            #expect(waiting.bounds == a)
            #expect(try alpha(waiting, at: CGPoint(x: a.midX, y: a.midY)) > 0.99)
        }
        let choice = handoff.choose(window: 2, bounds: b, picture: image(.blue), expectsPicture: true)
        let ready = try #require(choice)
        #expect(ready.bounds == b)
        #expect(try alpha(ready, at: CGPoint(x: b.midX, y: b.midY)) > 0.99)
    }

    @Test("Before the image fades, the preview has the source colours and remains opaque")
    func neutralImageMatchesSource() throws {
        let frame = PreviewHandoff<NSImage>.Frame(window: 1, bounds: a, picture: image(.red))
        let centre = CGPoint(x: a.midX, y: a.midY)
        let styled = try color(frame, at: centre)
        let neutral = try color(frame, at: centre, effects: 0, spotlight: true)
        #expect(styled.redComponent < 0.95)
        #expect(neutral.redComponent > 0.99)
        #expect(neutral.greenComponent < 0.01)
        #expect(neutral.blueComponent < 0.01)
        #expect(neutral.alphaComponent > 0.99)
    }

    @Test("Removing the selection styling also removes the border, guides and scrim")
    func neutralImageHasNoOuterEffects() throws {
        let frame = PreviewHandoff<NSImage>.Frame(window: 1, bounds: a, picture: image(.white))
        // The former expanded black backing extended 2.5 points beyond the window.
        let edge = try color(frame, at: CGPoint(x: a.maxX + 1, y: a.midY), effects: 0, spotlight: true)
        let desktop = try color(frame, at: CGPoint(x: 280, y: a.midY), effects: 0, spotlight: true)
        #expect(edge.alphaComponent < 0.01)
        #expect(desktop.alphaComponent < 0.01)
    }
}
