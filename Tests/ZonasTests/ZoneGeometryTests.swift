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
        let frames = Layout.threeColumns.zones.map { $0.frame(in: area) }

        #expect(frames[1].minX - frames[0].maxX == Zone.gap)
        #expect(frames[2].minX - frames[1].maxX == Zone.gap)
        // Half a gap against the screen edge, until `defaults.margin` exists.
        #expect(frames[0].minX - area.minX == Zone.gap / 2)
    }

    @Test("The frame sits centred inside its zone")
    func theFrameIsCentredInTheZone() {
        let zone = Zone(name: "Left", x: 0, y: 0, width: 0.25, height: 1)

        let rect = zone.rect(in: area)
        let frame = zone.frame(in: area)

        #expect(frame.midX == rect.midX)
        #expect(frame.midY == rect.midY)
        #expect(rect.contains(frame))
    }

    /// insetBy returns CGRect.null when the inset eats the rectangle, and
    /// CGRect.null's origin is infinity. A malformed file must not be able to
    /// send a window there.
    @Test("A zone thinner than the gap is left alone rather than inverted")
    func aTinyZoneKeepsItsRectangle() {
        let sliver = Zone(name: "Sliver", x: 0, y: 0, width: 0.0001, height: 1)

        let frame = sliver.frame(in: area)

        #expect(frame == sliver.rect(in: area))
        #expect(frame.width > 0)
        #expect(frame.origin.x.isFinite)
    }
}
