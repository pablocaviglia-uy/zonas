import Foundation
import Testing
@testable import Zonas

/// The ultrawide, sitting above the laptop, so CG's Y is negative all the way
/// across it. A layout drawn upside down looks identical to a correct one on
/// any symmetric layout, and this is the screen where it would not.
private let area = CGRect(x: 0, y: -1440, width: 5120, height: 1440)

/// Two rows, and they are not the same height. That asymmetry is the whole
/// point: with `0.5 / 0.5` a vertical mirror is invisible.
private let twoRows = Layout(
    name: "Two Rows",
    zones: [
        Zone(name: "Top",    x: 0, y: 0.00, width: 1, height: 0.25),
        Zone(name: "Bottom", x: 0, y: 0.25, width: 1, height: 0.75),
    ],
    gap: 0,
    margin: 0
)

/// The chain from a fraction in the file to a rectangle the editor draws, taken
/// end to end. Each link has its own tests; these are about them composing,
/// which is where the editor either is 1:1 with the screen or quietly is not.
@Suite("From a fraction in the file to a rectangle in the editor")
struct EditorGeometryTests {

    /// The production call, not a copy of it. Writing the expression out again
    /// here would have made every test below pass against an editor that draws
    /// something else entirely — which is the failure the tests exist to catch.
    private func drawn(_ layout: Layout) -> [CGRect] { layout.viewFrames(in: area) }

    /// `y: 0` is the top of the screen. The seed file says so in an ASCII
    /// diagram, `Zone.rect(in:)` believes it because CG counts downwards, and
    /// the editor's view counts upwards — so the claim survives exactly two
    /// sign conventions, and a layout drawn upside down is a layout that snaps
    /// windows to the correct place while showing you the wrong one.
    @Test("The zone written at y: 0 is drawn at the top")
    func theFirstRowIsTheTopRow() {
        let rows = drawn(twoRows)

        #expect(rows[0].maxY == area.height)     // "Top" is flush with the top
        #expect(rows[0].height == 360)           // and it is the quarter, not the three quarters
        #expect(rows[1].minY == 0)               // "Bottom" is flush with the bottom
        #expect(rows[1].height == 1080)
    }

    /// The editor covers `visibleFrame` and nothing else. A rectangle that comes
    /// out beyond the view's bounds is a rectangle drawn onto the menu bar or off
    /// the side of the monitor, and AppKit clips it rather than complaining.
    @Test("Nothing is drawn outside the window that draws it")
    func everythingFitsInsideTheWindow() {
        let bounds = CGRect(origin: .zero, size: area.size)

        for layout in [twoRows, Layout.threeColumns] {
            for rect in drawn(layout) {
                #expect(bounds.contains(rect))
            }
        }
    }

    /// With no gap and no margin, the rectangles the editor draws tile the
    /// window edge to edge and leave nothing over. This is the 1:1 claim stated
    /// end to end: the window is the usable area, so a layout that covers the
    /// screen covers the window.
    @Test("A layout that tiles the screen tiles the window")
    func theTilingSurvivesTheConversion() {
        let rows = drawn(twoRows)

        #expect(rows[0].minY == rows[1].maxY)
        #expect(rows.reduce(0) { $0 + $1.height } == area.height)
        #expect(rows.allSatisfy { $0.width == area.width })
    }

    /// Nothing between the file and the screen scales, so the gap is the same
    /// number of points in the editor that it is between two snapped windows.
    /// This is what a scaled editor could not promise, and §5 gave up the
    /// scaled editor to be able to.
    @Test("The gap is the same number of points in the editor as on the screen")
    func theGapIsNotScaled() {
        let columns = drawn(Layout.threeColumns)

        #expect(columns[1].minX - columns[0].maxX == Layout.defaultGap)
        #expect(columns[2].minX - columns[1].maxX == Layout.defaultGap)
        // And the outer edges are flush, because `threeColumns` has margin 0.
        #expect(columns[0].minX == 0)
        #expect(columns[2].maxX == area.width)
    }

    /// The counterpart of `viewFrames`, and the reason there are two functions.
    /// What the editor draws is separated by the gap; what it hit-tests is not,
    /// or the gutter between two zones becomes a band where clicking selects
    /// nothing and nothing on screen explains why.
    @Test("The hit regions tile the window even though the drawn ones do not")
    func hitRegionsTileTheWindow() {
        let layout = Layout.threeColumns          // gap 8
        let hits = layout.hitRects(in: area)
        let drawn = layout.viewFrames(in: area)

        #expect(hits[0].maxX == hits[1].minX)
        #expect(hits[1].maxX == hits[2].minX)
        #expect(hits[0].minX == 0)
        #expect(hits[2].maxX == area.width)
        #expect(drawn[1].minX - drawn[0].maxX == Layout.defaultGap)

        // A click in the gutter — outside both drawn rectangles — still lands
        // in a zone.
        let gutter = CGPoint(x: (drawn[0].maxX + drawn[1].minX) / 2, y: 700)
        #expect(drawn.allSatisfy { !$0.contains(gutter) })
        #expect(Layout.smallestIndex(containing: gutter, in: hits) != nil)
    }

    /// Smallest-wins, asked in the editor's coordinates rather than the drop's.
    /// A layout with one big zone behind a small one is what a config file is
    /// for, and the editor has to be able to reach the small one.
    @Test("A zone on top of a bigger one is the one the editor picks")
    func theSmallestZoneWinsInViewSpaceToo() {
        let layout = Layout(name: "Stacked", zones: [
            Zone(name: "Everything", x: 0,    y: 0,    width: 1,   height: 1),
            Zone(name: "Middle",     x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        ])
        let hits = layout.hitRects(in: area)

        let middle = CGPoint(x: area.width / 2, y: area.height / 2)
        let corner = CGPoint(x: 10, y: 10)
        #expect(Layout.smallestIndex(containing: middle, in: hits) == 1)
        #expect(Layout.smallestIndex(containing: corner, in: hits) == 0)
        #expect(Layout.smallestIndex(containing: CGPoint(x: -1, y: -1), in: hits) == nil)
    }

    /// The editor draws `frame` and the drop sets `frame` — the same call, with
    /// the same gap and the same margin. §3e was the bug where those two were
    /// different numbers living in different files, and the editor is the place
    /// where reintroducing it would be most expensive: there the drawing is not
    /// a preview of the product, it *is* the product.
    @Test("What the editor draws is the size a dropped window is given")
    func drawnIsTheSizeThatLands() {
        let layout = Layout(name: "Framed", zones: Layout.threeColumns.zones, gap: 24, margin: 16)

        for (zone, rect) in zip(layout.zones, drawn(layout)) {
            #expect(rect.size == layout.frame(of: zone, in: area).size)
        }
    }
}
