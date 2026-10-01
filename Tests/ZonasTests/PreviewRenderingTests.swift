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

    private func alpha(_ frame: PreviewHandoff<NSImage>.Frame, at point: CGPoint) throws -> CGFloat {
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
        view.show(hole: frame.bounds, picture: frame.picture, spotlight: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.colorAt(x: Int(point.x), y: 110 - Int(point.y))).alphaComponent
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
}
