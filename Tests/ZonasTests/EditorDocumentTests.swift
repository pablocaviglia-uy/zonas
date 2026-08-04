import Foundation
import Testing
@testable import Zonas

/// A screen-sized rectangle with an origin that is not the origin, so anything
/// that quietly assumes the area starts at zero fails here rather than on
/// somebody's second monitor.
private let area = CGRect(x: 0, y: -1440, width: 5120, height: 1440)

private func oneZone() -> EditorDocument {
    EditorDocument(Layout(name: "Whole",
                          zones: [Zone(name: "All", x: 0, y: 0, width: 1, height: 1)]))
}

/// Nothing in here is allowed to need a screen, a window or an event. Splitting
/// is arithmetic on fractions, and keeping it arithmetic is what makes the parts
/// that *do* need a screen small enough to check by hand.
///
/// (`#expect` cannot wrap a mutating call — the macro captures the receiver
/// immutably — so every `split` and `undo` is made on its own line and the
/// result is what gets asserted.)
@Suite("Cutting a zone in two")
struct EditorDocumentTests {

    // MARK: - The arithmetic

    @Test("A vertical cut leaves one piece beside the other")
    func verticalCutMakesColumns() {
        var doc = oneZone()
        let cut = doc.split(rid: doc.zones[0].rid, at: 0.25, .vertical, minimum: 0.01)

        #expect(cut)
        #expect(doc.zones.count == 2)
        #expect(doc.zones[0].x == 0)
        #expect(doc.zones[0].width == 0.25)
        #expect(doc.zones[1].x == 0.25)
        #expect(doc.zones[1].width == 0.75)
        // The cut is a cut: nothing is created and nothing is lost.
        #expect(doc.zones[0].height == 1)
        #expect(doc.zones[1].height == 1)
        let total = doc.zones.reduce(0.0) { $0 + $1.width }
        #expect(total == 1)
    }

    @Test("A horizontal cut leaves one piece above the other")
    func horizontalCutMakesRows() {
        var doc = oneZone()
        let cut = doc.split(rid: doc.zones[0].rid, at: 0.75, .horizontal, minimum: 0.01)

        #expect(cut)
        #expect(doc.zones[0].y == 0)
        #expect(doc.zones[0].height == 0.75)
        #expect(doc.zones[1].y == 0.75)
        #expect(doc.zones[1].height == 0.25)
        let total = doc.zones.reduce(0.0) { $0 + $1.height }
        #expect(total == 1)
    }

    /// Cutting a zone that does not start at zero. The offsets are where a
    /// split written against a full-screen zone stops working, and the middle
    /// column is the first place you would notice.
    @Test("Cutting a zone that is already a slice of the screen")
    func cuttingAnOffsetZone() {
        var doc = EditorDocument(.threeColumns)
        let centre = doc.zones[1]                      // x 0.25, width 0.5
        let cut = doc.split(rid: centre.rid, at: 0.5, .vertical, minimum: 0.01)

        #expect(cut)
        #expect(doc.zones[1].x == 0.25)
        #expect(doc.zones[1].width == 0.25)
        #expect(doc.zones[2].x == 0.5)
        #expect(doc.zones[2].width == 0.25)
        // The piece that used to be on the right is still on the right.
        #expect(doc.zones[3].name == "Right")
    }

    @Test("The new zone is inserted next to the one it came from")
    func theNewZoneGoesBesideItsParent() {
        var doc = EditorDocument(.threeColumns)
        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)

        #expect(doc.zones.map(\.name) == ["Left", "Left 2", "Center", "Right"])
    }

    // MARK: - Refusing

    /// A click near an edge is a click near an edge, not a request for a zone
    /// with no width. Refusing rather than clamping is on purpose: clamping
    /// would put a zone where you did not click.
    @Test("A cut too close to an edge does nothing at all")
    func aCutTooCloseIsRefused() {
        var doc = oneZone()
        let before = doc

        let tooNear = doc.split(rid: doc.zones[0].rid, at: 0.005, .vertical, minimum: 0.01)
        let tooFar = doc.split(rid: doc.zones[0].rid, at: 0.995, .vertical, minimum: 0.01)

        #expect(tooNear == false)
        #expect(tooFar == false)
        #expect(doc == before)
        #expect(doc.canUndo == false)   // and it did not consume an undo step either
    }

    @Test("Splitting something that is not there does nothing")
    func splittingAnUnknownZoneIsRefused() {
        var doc = oneZone()
        let cut = doc.split(rid: 9999, at: 0.5, .vertical, minimum: 0.01)

        #expect(cut == false)
        #expect(doc.zones.count == 1)
    }

    // MARK: - Names

    /// `name` is the file's handle and the thing drawn across the zone. Two
    /// zones called "Left" were a bug before anything could write them.
    @Test("Every zone a split produces has a name nobody else has")
    func namesStayUnique() {
        var doc = oneZone()
        for _ in 0..<5 {
            doc.split(rid: doc.zones[0].rid, at: doc.zones[0].width / 2, .vertical, minimum: 0.001)
        }

        #expect(doc.zones.count == 6)
        #expect(Set(doc.zones.map(\.name)).count == 6)
    }

    /// Three splits deep, "All 2 2 2" is unreadable, and it is what you get by
    /// default unless the trailing number is stripped before counting.
    @Test("Splitting a zone that already has a number counts on, it does not nest")
    func numbersDoNotNest() {
        var doc = oneZone()
        doc.split(rid: doc.zones[0].rid, at: 0.5, .vertical, minimum: 0.01)
        #expect(doc.zones.map(\.name) == ["All", "All 2"])

        doc.split(rid: doc.zones[1].rid, at: 0.75, .vertical, minimum: 0.01)
        #expect(doc.zones.map(\.name) == ["All", "All 2", "All 3"])
    }

    @Test("A name that merely ends in a word is left alone")
    func onlyTrailingNumbersAreStripped() {
        var doc = EditorDocument(Layout(name: "L",
            zones: [Zone(name: "Chat Window", x: 0, y: 0, width: 1, height: 1)]))
        doc.split(rid: doc.zones[0].rid, at: 0.5, .vertical, minimum: 0.01)

        #expect(doc.zones.map(\.name) == ["Chat Window", "Chat Window 2"])
    }

    // MARK: - Identity

    /// The point of `rid`: it is not the index, and it survives the array
    /// moving underneath it. Selection and undo hang off this, and an index
    /// would be silently wrong the first time a split inserted above it.
    @Test("A zone keeps its identity when another one is inserted before it")
    func ridSurvivesInsertion() {
        var doc = EditorDocument(.threeColumns)
        let right = doc.zones[2].rid
        #expect(doc.index(of: right) == 2)

        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)

        #expect(doc.index(of: right) == 3)
        #expect(doc.zones[3].name == "Right")
    }

    @Test("No two zones ever share an rid, however many splits")
    func ridsAreNeverReused() {
        var doc = oneZone()
        for _ in 0..<8 {
            doc.split(rid: doc.zones[0].rid, at: doc.zones[0].width / 2, .vertical, minimum: 0.0001)
        }

        #expect(Set(doc.zones.map(\.rid)).count == doc.zones.count)
    }

    // MARK: - Undo

    @Test("Undo puts the document back exactly")
    func undoRestoresTheDocument() {
        var doc = EditorDocument(.threeColumns)
        let before = doc

        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)
        #expect(doc != before)

        let undone = doc.undo()
        #expect(undone)
        #expect(doc == before)
    }

    @Test("Undo goes all the way back, and then stops")
    func undoUnwindsAndStops() {
        var doc = oneZone()
        let before = doc
        doc.split(rid: doc.zones[0].rid, at: 0.5, .vertical, minimum: 0.01)
        doc.split(rid: doc.zones[1].rid, at: 0.75, .horizontal, minimum: 0.01)
        #expect(doc.zones.count == 3)

        doc.undo()
        doc.undo()
        #expect(doc == before)
        #expect(doc.canUndo == false)

        let again = doc.undo()
        #expect(again == false)
    }

    /// Whether the document has been touched is what decides if a save from
    /// outside may replace it. A document you have undone back to the start has
    /// not been touched, and should follow the file again.
    @Test("A document undone back to the start counts as untouched")
    func undoingEverythingClearsTheEditedFlag() {
        var doc = oneZone()
        #expect(doc.isEdited == false)

        doc.split(rid: doc.zones[0].rid, at: 0.5, .vertical, minimum: 0.01)
        #expect(doc.isEdited)

        doc.undo()
        #expect(doc.isEdited == false)
    }

    // MARK: - Back to a layout

    /// The document draws and snaps through `Layout`, so what it hands back has
    /// to be a layout in every respect — including the settings it does not let
    /// you edit, which would otherwise silently reset to the defaults the moment
    /// you opened the editor.
    @Test("The layout that comes back keeps the settings that went in")
    func settingsSurviveTheRoundTrip() {
        let original = Layout(name: "Framed", zones: Layout.threeColumns.zones,
                              gap: 24, margin: 16, modifier: .control)

        #expect(EditorDocument(original).layout == original)
    }

    @Test("The pieces of a split tile exactly what the original covered")
    func splittingPreservesTheGeometry() {
        var doc = EditorDocument(.threeColumns)
        let before = doc.layout.hitRects(in: area)

        doc.split(rid: doc.zones[1].rid, at: 0.5, .vertical, minimum: 0.01)
        let after = doc.layout.hitRects(in: area)

        #expect(after.count == before.count + 1)
        #expect(after[1].minX == before[1].minX)
        #expect(after[2].maxX == before[1].maxX)
        #expect(after[1].maxX == after[2].minX)   // no seam, no overlap
    }

    // MARK: - The default axis

    /// §5's claim that the five-zone ultrawide is five clicks with no modifier
    /// rests entirely on this turning itself round.
    @Test("The default cut is perpendicular to the longest side")
    func theDefaultCutFollowsTheShape() {
        #expect(Cut.default(for: CGRect(x: 0, y: 0, width: 5120, height: 1440)) == .vertical)
        #expect(Cut.default(for: CGRect(x: 0, y: 0, width: 1280, height: 1440)) == .horizontal)
        #expect(Cut.default(for: CGRect(x: 0, y: 0, width: 1280, height: 720)) == .vertical)
        // A square has to answer something; it answers the same thing twice.
        #expect(Cut.default(for: CGRect(x: 0, y: 0, width: 500, height: 500)) == .vertical)
        #expect(Cut.vertical.rotated == .horizontal)
        #expect(Cut.horizontal.rotated == .vertical)
    }
}
