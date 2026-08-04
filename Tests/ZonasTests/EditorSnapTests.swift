import Foundation
import Testing
@testable import Zonas

private func desk() -> EditorDocument {
    EditorDocument(Layout(name: "Desk", zones: [
        Zone(name: "Top Left",    x: 0,    y: 0,   width: 0.25, height: 0.5),
        Zone(name: "Bottom Left", x: 0,    y: 0.5, width: 0.25, height: 0.5),
        Zone(name: "Centre",      x: 0.25, y: 0,   width: 0.5,  height: 1),
        Zone(name: "Right",       x: 0.75, y: 0,   width: 0.25, height: 1),
    ]))
}

private func rid(_ doc: EditorDocument, _ name: String) -> Int {
    doc.zones.first { $0.name == name }!.rid
}

/// Ten points of a 5120-point screen, which is the radius the editor uses.
private let radius = 10.0 / 5120

@Suite("Landing on a number worth writing down")
struct EditorSnapTests {

    // MARK: - The order of preference

    /// Lining up with something already on the screen is what you are almost
    /// always trying to do, and no fraction substitutes for it: a zone flush
    /// with its neighbour above is right whether or not the number is pretty.
    @Test("Another zone's edge beats a rational line")
    func neighboursComeFirst() {
        let doc = EditorDocument(Layout(name: "Offset", zones: [
            Zone(name: "A", x: 0,    y: 0,   width: 0.51, height: 0.5),
            Zone(name: "B", x: 0,    y: 0.5, width: 0.3,  height: 0.5),
        ]))

        // 0.505 is within reach of both A's edge at 0.51 and the half at 0.5.
        #expect(doc.snap(0.505, along: .vertical, ignoring: [rid(doc, "B")], within: 0.02) == 0.51)
    }

    @Test("A rational line is where an unremarkable number lands")
    func theGridCatchesTheRest() {
        let doc = desk()
        let moving = Set(doc.zones.map(\.rid))    // ignore every neighbour

        #expect(doc.snap(0.3333, along: .vertical, ignoring: moving, within: radius) == 1.0 / 3)
        #expect(doc.snap(0.6667, along: .vertical, ignoring: moving, within: radius) == 2.0 / 3)
        #expect(doc.snap(0.1252, along: .vertical, ignoring: moving, within: radius) == 1.0 / 8)
    }

    /// The one that matters: a value that came off a cursor is not a fraction,
    /// and after snapping it is one **exactly** — the same bits the file would
    /// parse. That is what stops `0.3333333333333333` reaching anybody's
    /// dotfiles.
    @Test("What comes back is exactly what the file would read")
    func snappingProducesTheFilesOwnValue() {
        let doc = desk()
        let moving = Set(doc.zones.map(\.rid))
        let cursor = 0.33298611111    // a real cursor position on the ultrawide

        let snapped = doc.snap(cursor, along: .vertical, ignoring: moving, within: radius)

        #expect(snapped == Double(1) / Double(3))
        #expect(Fraction.describe(snapped) == "1/3")
    }

    @Test("Nothing in reach means nothing moves")
    func aValueFarFromEverythingIsLeftAlone() {
        let doc = desk()
        let moving = Set(doc.zones.map(\.rid))
        // 0.27 is more than ten points from any line on a 5120-point screen.
        #expect(doc.snap(0.27, along: .vertical, ignoring: moving, within: radius) == 0.27)
    }

    /// A line that snapped to where it already was could not be moved at all.
    ///
    /// The divider here is at 0.27 rather than at a quarter on purpose: a
    /// quarter is a rational line as well as a neighbour's edge, so ignoring
    /// the neighbour proves nothing — the grid catches it anyway. That is
    /// exactly what the first draft of this test did, and it failed for the
    /// right reason.
    @Test("The zones being moved do not attract the line that is moving them")
    func theMovingZonesAreIgnored() {
        let doc = EditorDocument(Layout(name: "Odd", zones: [
            Zone(name: "L", x: 0,    y: 0, width: 0.27, height: 1),
            Zone(name: "R", x: 0.27, y: 0, width: 0.73, height: 1),
        ]))
        let onTheLine = Set(doc.zones.map(\.rid))

        #expect(doc.snap(0.2705, along: .vertical, ignoring: onTheLine, within: radius) == 0.2705)
        // And with nothing ignored, that same edge pulls it straight back.
        #expect(doc.snap(0.2705, along: .vertical, ignoring: [], within: radius) == 0.27)
    }

    /// Without a range the grid can pull a cut into the band where it would be
    /// refused, and the result is a stripe of screen where hovering shows
    /// nothing and no reason is given.
    @Test("A target outside the allowed range is not offered")
    func theRangeIsRespected() {
        let doc = desk()
        let moving = Set(doc.zones.map(\.rid))

        #expect(doc.snap(0.3333, along: .vertical, ignoring: moving,
                         within: radius, to: 0.4...0.6) == 0.3333)
        #expect(doc.snap(0.4995, along: .vertical, ignoring: moving,
                         within: radius, to: 0.4...0.6) == 0.5)
    }

    @Test("A radius of nothing snaps to nothing — which is what ⌥ asks for")
    func optionTurnsItOff() {
        let doc = desk()
        #expect(doc.snap(0.3333, along: .vertical, ignoring: [], within: 0) == 0.3333)
    }

    // MARK: - Snapping and dragging together

    /// The payoff, end to end: a divider dragged to roughly a third leaves a
    /// document whose numbers a person would have typed.
    @Test("A divider dragged to about a third lands on exactly a third")
    func aDraggedDividerLandsOnACleanNumber() {
        var doc = desk()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)!
        let moving = Set(edge.leading + edge.trailing)
        let target = doc.snap(0.3341, along: .vertical, ignoring: moving, within: radius)

        doc.move(edge, to: target, minimum: 0.01)

        #expect(Fraction.describe(doc.zones[0].width) == "1/3")
        #expect(Fraction.describe(doc.zones[2].x) == "1/3")
        // And the zone that lost the space reads as a fraction too, which is the
        // thing that would not have happened without an exact grid: 3/4 − 1/3.
        #expect(Fraction.describe(doc.zones[2].width) == "5/12")
    }
}

@Suite("Deleting a zone")
struct EditorDeleteTests {

    @Test("The neighbour sharing the longest edge takes the area")
    func theLongestNeighbourInherits() {
        var doc = desk()
        // "Centre" touches Top Left and Bottom Left over half its height each,
        // and "Right" over all of it — so Right inherits.
        let deleted = doc.delete(rid: rid(doc, "Centre"))

        #expect(deleted)
        #expect(doc.zones.map(\.name) == ["Top Left", "Bottom Left", "Right"])
        let right = doc.zones[2]
        #expect(right.x == 0.25)
        #expect(right.width == 0.75)
        #expect(right.height == 1)
    }

    @Test("The area really is absorbed — the layout still tiles")
    func nothingIsLeftBehind() {
        var doc = EditorDocument(Layout(name: "Rows", zones: [
            Zone(name: "Top",    x: 0, y: 0,   width: 1, height: 0.25),
            Zone(name: "Middle", x: 0, y: 0.25, width: 1, height: 0.25),
            Zone(name: "Bottom", x: 0, y: 0.5, width: 1, height: 0.5),
        ]))

        doc.delete(rid: rid(doc, "Middle"))

        #expect(doc.zones.map(\.name) == ["Top", "Bottom"])
        // Both run the full width, so both line up exactly and the tie goes to
        // the file's own order. "Top" grows down; nothing is left over.
        #expect(doc.zones[0].y == 0)
        #expect(doc.zones[0].height == 0.5)
        #expect(doc.zones[0].y + doc.zones[0].height == doc.zones[1].y)
        #expect(doc.zones[1].y + doc.zones[1].height == 1)
    }

    /// **The case that killed "longest shared edge".** Deleting "Top Left"
    /// offers two neighbours: "Bottom Left" underneath it, sharing a quarter of
    /// the screen's width, and "Centre" beside it, sharing half its height.
    /// Which of those is longer depends on the monitor — 1280 against 720 points
    /// on the ultrawide, 432 against 542 on the laptop — so length alone would
    /// absorb into a different zone on each screen, for one layout drawn on
    /// both. Lining up exactly is the question that has the same answer
    /// everywhere, and it picks the zone in the same column, which is the one
    /// anybody would point at.
    ///
    /// It also keeps the heir from growing both ways, which would swallow
    /// whatever else was beside the victim — deleting one zone and silently
    /// covering two.
    @Test("The heir is the neighbour that lines up, not the one with the longest edge")
    func theHeirDoesNotGrowSideways() {
        var doc = desk()
        doc.delete(rid: rid(doc, "Top Left"))

        let heir = doc.zones.first { $0.name == "Bottom Left" }!
        #expect(heir.y == 0)
        #expect(heir.height == 1)
        #expect(heir.width == 0.25)     // and not across into Centre
    }

    @Test("An empty layout is not reachable")
    func theLastZoneStays() {
        var doc = EditorDocument(Layout(name: "One",
            zones: [Zone(name: "All", x: 0, y: 0, width: 1, height: 1)]))

        let deleted = doc.delete(rid: doc.zones[0].rid)

        #expect(deleted == false)
        #expect(doc.zones.count == 1)
        #expect(doc.canUndo == false)
    }

    @Test("Deleting is one undo step and goes back exactly")
    func deletingIsUndoable() {
        var doc = desk()
        let before = doc

        doc.delete(rid: rid(doc, "Centre"))
        doc.undo()

        #expect(doc == before)
    }

    /// A zone with no neighbour at all — floating on top of a bigger one, which
    /// is exactly what smallest-wins exists to support — simply goes.
    @Test("A zone nobody touches leaves a hole, and that is allowed")
    func anIslandJustGoes() {
        var doc = EditorDocument(Layout(name: "Island", zones: [
            Zone(name: "Everything", x: 0,   y: 0,   width: 1,   height: 1),
            Zone(name: "Floating",   x: 0.3, y: 0.3, width: 0.2, height: 0.2),
        ]))

        let deleted = doc.delete(rid: rid(doc, "Floating"))

        #expect(deleted)
        #expect(doc.zones.map(\.name) == ["Everything"])
        #expect(doc.zones[0].width == 1)   // nothing grew: there was nothing to grow into
    }
}
