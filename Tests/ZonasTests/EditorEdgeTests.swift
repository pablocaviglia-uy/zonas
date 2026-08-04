import Foundation
import Testing
@testable import Zonas

/// The layout on this desk, which is the useful one to reason against: the left
/// quarter is two stacked zones, the middle half and the right quarter are full
/// height. The vertical line at x = 0.25 therefore has **three** zones on it,
/// two of which only touch each other, and that is the case the coalescence rule
/// exists for.
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

/// Fractions come out of subtraction, so they carry the usual binary residue:
/// clamping a line to `0.75 - 0.1` and then asking how wide the zone is gives
/// `0.09999999999999998`. The tolerance is a billionth of a screen — five
/// millionths of a point on the ultrawide, which is thousands of times smaller
/// than a pixel — so a real crack of a thousandth still fails here and IEEE 754
/// does not.
private func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite("Grabbing a divider")
struct EditorEdgeTests {

    // MARK: - Which zones come with it

    /// The whole point of coalescence: one number moves, so the zones on both
    /// sides of a boundary cannot come apart. Two of the three zones here only
    /// *touch* — "Top Left" ends where "Bottom Left" begins — and they are
    /// plainly one line to anybody looking at the screen.
    @Test("Every zone on the line comes with it, including ones that only touch")
    func theWholeLineIsGathered() {
        let doc = desk()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)

        #expect(edge?.leading == [rid(doc, "Centre")])
        #expect(edge?.trailing.count == 2)
        #expect(Set(edge?.trailing ?? []) == Set([rid(doc, "Top Left"), rid(doc, "Bottom Left")]))
        #expect(edge?.from == 0)
        #expect(edge?.to == 1)
    }

    /// The same claim with **nothing bridging the two halves**, which is what
    /// actually tests it: four zones meeting at one line, stacked two and two,
    /// so the upper pair and the lower pair share no interior at all and meet
    /// only at a point. Breaking the rule to demand a strict overlap passes the
    /// test above — "Centre" runs the full height and joins everything to
    /// everything — and fails this one, which is the difference between a test
    /// that exists and a test that bites.
    @Test("Two stacked pairs meeting at one line are still one line")
    func extentsThatOnlyTouchAreStillJoined() {
        let doc = EditorDocument(Layout(name: "Quarters", zones: [
            Zone(name: "TL", x: 0,   y: 0,   width: 0.5, height: 0.5),
            Zone(name: "TR", x: 0.5, y: 0,   width: 0.5, height: 0.5),
            Zone(name: "BL", x: 0,   y: 0.5, width: 0.5, height: 0.5),
            Zone(name: "BR", x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ]))

        let edge = doc.edge(along: .vertical, near: 0.5, across: 0.2, within: 0.01)

        #expect(edge?.zoneCount == 4)
        #expect(edge?.from == 0)
        #expect(edge?.to == 1)
    }

    /// A crack of a thousandth — what a file with `0.3333` on one side and `1/3`
    /// on the other looks like — is one line, and dragging it closes the crack.
    @Test("Edges a hairline apart are the same line")
    func aHairlineCrackIsStillOneLine() {
        var doc = EditorDocument(Layout(name: "Cracked", zones: [
            Zone(name: "L", x: 0,      y: 0, width: 0.3333, height: 1),
            Zone(name: "R", x: 0.3334, y: 0, width: 0.6666, height: 1),
        ]))
        let edge = doc.edge(along: .vertical, near: 0.3333, across: 0.5, within: 0.01)
        #expect(edge?.zoneCount == 2)

        doc.move(edge!, to: 0.5, minimum: 0.01)
        #expect(isClose(doc.zones[0].x + doc.zones[0].width, doc.zones[1].x))  // no crack left
    }

    /// And a deliberate gap is not. Two per cent of the screen is not a rounding
    /// error, and gathering it would silently close something somebody wrote.
    @Test("A deliberate gap is two lines, not one")
    func aDeliberateGapIsLeftAlone() {
        let doc = EditorDocument(Layout(name: "Gapped", zones: [
            Zone(name: "L", x: 0,    y: 0, width: 0.3, height: 1),
            Zone(name: "R", x: 0.32, y: 0, width: 0.68, height: 1),
        ]))

        #expect(doc.edge(along: .vertical, near: 0.30, across: 0.5, within: 0.01)?.zoneCount == 1)
        #expect(doc.edge(along: .vertical, near: 0.32, across: 0.5, within: 0.01)?.zoneCount == 1)
    }

    /// Reach and tolerance are different numbers, and here is the case that says
    /// so out loud: the cursor is far enough from the line that a single shared
    /// number would have to be at least this big, and a second line that far
    /// away must still not be gathered.
    @Test("Reaching a line is not the same as gathering everything near it")
    func reachAndToleranceAreDifferentNumbers() {
        let doc = EditorDocument(Layout(name: "Gapped", zones: [
            Zone(name: "L", x: 0,    y: 0, width: 0.3,  height: 1),
            Zone(name: "R", x: 0.32, y: 0, width: 0.68, height: 1),
        ]))

        // Reaching from between the two, nearer to the first.
        let edge = doc.edge(along: .vertical, near: 0.305, across: 0.5, within: 0.02)

        #expect(edge?.coordinate == 0.3)
        #expect(edge?.zoneCount == 1)      // the other line is reachable, not collinear
    }

    /// A vertical line broken in the middle by a full-width zone is two
    /// dividers. Moving the top one must not move the bottom one, and the thing
    /// that tells them apart is where along the line you grabbed.
    @Test("A line broken by a full-width zone is two lines")
    func abrokenLineIsTwoLines() {
        let doc = EditorDocument(Layout(name: "Broken", zones: [
            Zone(name: "TL",   x: 0,   y: 0,   width: 0.5, height: 0.3),
            Zone(name: "TR",   x: 0.5, y: 0,   width: 0.5, height: 0.3),
            Zone(name: "Band", x: 0,   y: 0.3, width: 1,   height: 0.4),
            Zone(name: "BL",   x: 0,   y: 0.7, width: 0.5, height: 0.3),
            Zone(name: "BR",   x: 0.5, y: 0.7, width: 0.5, height: 0.3),
        ]))

        let top = doc.edge(along: .vertical, near: 0.5, across: 0.1, within: 0.01)
        let bottom = doc.edge(along: .vertical, near: 0.5, across: 0.9, within: 0.01)

        #expect(top?.zoneCount == 2)
        #expect(bottom?.zoneCount == 2)
        #expect(Set(top?.trailing ?? []) == Set([rid(doc, "TL")]))
        #expect(Set(bottom?.trailing ?? []) == Set([rid(doc, "BL")]))
        #expect(top?.to == 0.3)
        #expect(bottom?.from == 0.7)
    }

    /// The screen's own boundary is not a divider. Dragging it would only pull
    /// the layout off the edge, which is what `margin` is for, and it would
    /// happen by accident every time somebody aimed at the first zone.
    @Test("The edges of the screen cannot be grabbed")
    func theScreenIsNotADivider() {
        let doc = desk()

        #expect(doc.edge(along: .vertical, near: 0, across: 0.5, within: 0.01) == nil)
        #expect(doc.edge(along: .vertical, near: 1, across: 0.5, within: 0.01) == nil)
        #expect(doc.edge(along: .horizontal, near: 0, across: 0.5, within: 0.01) == nil)
        #expect(doc.edge(along: .horizontal, near: 1, across: 0.5, within: 0.01) == nil)
    }

    @Test("Nothing is grabbed where there is no line")
    func nothingWhereThereIsNoLine() {
        let doc = desk()
        #expect(doc.edge(along: .vertical, near: 0.5, across: 0.5, within: 0.01) == nil)
        // The horizontal line at y = 0.5 only exists in the left quarter.
        #expect(doc.edge(along: .horizontal, near: 0.5, across: 0.1, within: 0.01)?.zoneCount == 2)
        #expect(doc.edge(along: .horizontal, near: 0.5, across: 0.6, within: 0.01) == nil)
    }

    // MARK: - Moving it

    @Test("Both sides of the line move by the one number")
    func bothSidesMoveTogether() {
        var doc = desk()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)!

        let moved = doc.move(edge, to: 0.4, minimum: 0.01)

        #expect(moved)
        #expect(doc.zones[0].width == 0.4)      // Top Left grew
        #expect(doc.zones[1].width == 0.4)      // Bottom Left grew
        #expect(doc.zones[2].x == 0.4)          // Centre's origin moved
        #expect(doc.zones[2].width == 0.35)     // and it lost exactly what they gained
        #expect(doc.zones[3].x == 0.75)         // Right never touched
        // Still tiling, which is the property the whole rule exists to keep.
        #expect(isClose(doc.zones[0].x + doc.zones[0].width, doc.zones[2].x))
        #expect(isClose(doc.zones[2].x + doc.zones[2].width, doc.zones[3].x))
    }

    @Test("A horizontal line moves the zones above and below it")
    func horizontalLinesWorkTheSameWay() {
        var doc = desk()
        let edge = doc.edge(along: .horizontal, near: 0.5, across: 0.1, within: 0.01)!

        let moved = doc.move(edge, to: 0.25, minimum: 0.01)

        #expect(moved)
        #expect(doc.zones[0].height == 0.25)
        #expect(doc.zones[1].y == 0.25)
        #expect(doc.zones[1].height == 0.75)
        #expect(doc.zones[2].height == 1)       // the full-height zones are untouched
    }

    /// A drag is continuous — you are already holding the line — so it stops
    /// against the limit rather than refusing. That is the opposite of the
    /// split's answer, and deliberately so.
    @Test("A line stops against the smallest zone it would create")
    func draggingIsClampedNotRefused() {
        var doc = desk()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)!

        let moved = doc.move(edge, to: 0.99, minimum: 0.1)
        #expect(moved)

        // Centre runs to 0.75, so the line cannot pass 0.75 − 0.1.
        #expect(doc.zones[2].x == 0.65)
        #expect(isClose(doc.zones[2].width, 0.1))
        #expect(doc.zones[0].width == 0.65)
    }

    @Test("A line dragged back to where it started is not an undo step")
    func aDragThatChangesNothingIsNotRecorded() {
        var doc = desk()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)!

        let moved = doc.move(edge, to: 0.25, minimum: 0.01)
        #expect(moved == false)
        #expect(doc.canUndo == false)
        #expect(doc.isEdited == false)
    }

    @Test("Moving a line is one undo step, and it goes back exactly")
    func movingIsUndoable() {
        var doc = desk()
        let before = doc
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.2, within: 0.01)!

        doc.move(edge, to: 0.4, minimum: 0.01)
        doc.undo()
        #expect(doc == before)
    }

    // MARK: - ⌥ breaks it

    /// Without this the editor would be **less expressive than the file**, and
    /// §5 is explicit that it must not be: `zone(under:in:)` implements
    /// smallest-wins precisely so overlapping zones work, so the editor has to
    /// be able to make them.
    @Test("⌥ moves one zone's side and leaves its neighbours alone")
    func optionMovesASingleSide() {
        var doc = desk()
        let solo = doc.side(of: rid(doc, "Centre"), along: .vertical, nearest: 0.25)!

        let moved = doc.move(solo, to: 0.4, minimum: 0.01)

        #expect(solo.isAlone)
        #expect(moved)

        #expect(doc.zones[2].x == 0.4)          // Centre's left side moved
        #expect(doc.zones[0].width == 0.25)     // and the two on its left did not
        #expect(doc.zones[1].width == 0.25)
        // Which is a gap, made on purpose, that coalescence would have refused.
        #expect(doc.zones[0].x + doc.zones[0].width < doc.zones[2].x)
    }

    @Test("⌥ picks the side of that zone nearest where you grabbed")
    func optionPicksTheNearerSide() {
        let doc = desk()
        let centre = rid(doc, "Centre")

        #expect(doc.side(of: centre, along: .vertical, nearest: 0.25)?.leading == [centre])
        #expect(doc.side(of: centre, along: .vertical, nearest: 0.75)?.trailing == [centre])
    }
}
