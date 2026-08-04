import Foundation
import Testing
@testable import Zonas

/// The ultrawide this was written on, offset so that a bug that assumes the
/// area starts at the origin shows up here instead of on somebody's second
/// monitor.
private let area = CGRect(x: 100, y: 50, width: 5120, height: 1440)

@Suite("Turning zones into rectangles")
struct ZoneGeometryTests {

    @Test("Fractions land where the arithmetic says they do")
    func fractionsBecomePoints() {
        let zone = Zone(name: "Center", x: 0.25, y: 0, width: 0.5, height: 1)

        #expect(zone.rect(in: area) == CGRect(x: 1380, y: 50, width: 2560, height: 1440))
    }

    /// Hit regions tile. This is what keeps the gap from carving dead bands
    /// across the screen: with the inset applied to `rect` instead of `frame`,
    /// every boundary would become 8 points where a drop does nothing.
    @Test("Neighbouring zones share their edge exactly")
    func hitRegionsTile() {
        let rects = Layout.threeColumns.zones.map { $0.rect(in: area) }

        #expect(rects[0].maxX == rects[1].minX)
        #expect(rects[1].maxX == rects[2].minX)
        #expect(rects[0].minX == area.minX)
        #expect(rects[2].maxX == area.maxX)
    }

    /// And the frames do not: that separation is the gap, and it is the whole
    /// visible effect of the setting.
    @Test("Neighbouring windows are separated by exactly the gap")
    func framesAreSeparatedByTheGap() {
        let frames = Layout.threeColumns.zones.map { Layout.threeColumns.frame(of: $0, in: area) }

        #expect(frames[1].minX - frames[0].maxX == Layout.defaultGap)
        #expect(frames[2].minX - frames[1].maxX == Layout.defaultGap)
    }

    /// The reason gap and margin are two settings and not one. With a single
    /// number, `margin: 0` would still leave half a gap all the way around the
    /// outside and there would be no way to write "flush against the edge".
    @Test("The outside edge gets the margin, not half a gap")
    func theOutsideGetsTheMargin() {
        let flush = Layout.threeColumns
        let framed = Layout(name: "Framed", zones: flush.zones, gap: 8, margin: 20)

        #expect(flush.margin == 0)
        #expect(flush.frame(of: flush.zones[0], in: area).minX - area.minX == 0)
        #expect(framed.frame(of: framed.zones[0], in: area).minX - area.minX == 20)
        // The inner edges are still the gap's business either way.
        #expect(framed.frame(of: framed.zones[1], in: area).minX
                - framed.frame(of: framed.zones[0], in: area).maxX == 8)
    }

    /// A zone with neighbours on both sides gives up half a gap on each, so it
    /// stays centred. One against the edge does not, and should not.
    @Test("A zone between two others sits centred inside it")
    func theFrameIsCentredInTheZone() {
        let layout = Layout.threeColumns
        let middle = layout.zones[1]

        let rect = middle.rect(in: area)
        let frame = layout.frame(of: middle, in: area)

        #expect(frame.midX == rect.midX)
        #expect(rect.contains(frame))
    }

    /// A malformed file must not be able to hand the Accessibility API a
    /// rectangle no window can occupy.
    ///
    /// This one caught a real bug: the guard was written against the resulting
    /// rect, and `CGRect.width` returns the **absolute value** of what is
    /// stored, so a rect built 3.488 points wide in the wrong direction answers
    /// 3.488 when asked how wide it is. The guard passed every time and
    /// protected nothing.
    @Test("A zone thinner than its own gap is left alone rather than inverted")
    func aTinyZoneKeepsItsRectangle() {
        let sliver = Zone(name: "Sliver", x: 0, y: 0, width: 0.0001, height: 1)

        let frame = Layout.threeColumns.frame(of: sliver, in: area)

        #expect(frame == sliver.rect(in: area))
        #expect(frame.size.width > 0, "the rectangle came back inside out")
        #expect(frame.origin.x.isFinite)
    }
}
