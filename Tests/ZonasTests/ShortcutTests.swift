import Foundation
import Testing
@testable import Zonas

/// The layout in use on the machine this was written on, verbatim: two zones
/// stacked on the left, a wide middle, two stacked on the right — with the
/// right-hand pair split at 0.476526 rather than a half, which is what the
/// editor wrote after a drag and which is why several of the numbers below
/// are not round.
private let layout = Layout(name: "Tres columnas", zones: [
    Zone(name: "Izquierda Arriba", x: 0,    y: 0,        width: 0.25, height: 0.5),
    Zone(name: "Izquierda Abajo",  x: 0,    y: 0.5,      width: 0.25, height: 0.5),
    Zone(name: "Centro",           x: 0.25, y: 0,        width: 0.5,  height: 1),
    Zone(name: "Derecha 3",        x: 0.75, y: 0,        width: 0.25, height: 0.476526),
    Zone(name: "Derecha 4",        x: 0.75, y: 0.476526, width: 0.25, height: 0.523474),
])
private let arriba = 0, abajo = 1, centro = 2, derecha3 = 3, derecha4 = 4

/// The ultrawide, below its menu bar.
private let area = CGRect(x: 0, y: 30, width: 5120, height: 1410)

/// Where a window sits once it has been snapped into a zone: the frame, gap
/// and margin included, which is what the Accessibility API reads back.
private func snapped(_ index: Int) -> CGRect {
    layout.frame(of: layout.zones[index], in: area)
}

@Suite("Moving the front window with the arrows")
struct NeighbourTests {

    @Test("→ from the top-left zone is the middle, not the far column")
    func rightFromTheCorner() {
        #expect(layout.neighbour(of: snapped(arriba), towards: .right, in: area) == centro)
    }

    @Test("↓ from the top-left zone is the one below it, and the middle does not count as below")
    func downFromTheCorner() {
        #expect(layout.neighbour(of: snapped(arriba), towards: .down, in: area) == abajo)
    }

    @Test("↑ from the bottom-left zone is the one above")
    func upFromTheBottom() {
        #expect(layout.neighbour(of: snapped(abajo), towards: .up, in: area) == arriba)
    }

    @Test("→ from the right-hand zones goes nowhere — there is nothing right of them")
    func rightFromTheEdge() {
        #expect(layout.neighbour(of: snapped(derecha4), towards: .right, in: area) == nil)
        #expect(layout.neighbour(of: snapped(derecha3), towards: .right, in: area) == nil)
    }

    @Test("← from the middle is the upper of the two zones the column is beside")
    func leftFromTheMiddle() {
        // Both left-hand zones are flush against Centro and the column covers
        // both. The top one wins, and it wins every time.
        for _ in 0 ..< 3 {
            #expect(layout.neighbour(of: snapped(centro), towards: .left, in: area) == arriba)
        }
    }

    /// The report this rule exists for. The right-hand pair is split at
    /// 0.476526, so the line from the middle of the column runs into the
    /// *lower* zone — and → from the top-left corner, through the middle, came
    /// out at the bottom-right. A full-height column is beside both, and the
    /// top one is the answer whichever row you came from.
    @Test("→ from the middle is the upper right-hand zone, not the one across from its centre line")
    func rightFromTheMiddle() {
        #expect(layout.neighbour(of: snapped(centro), towards: .right, in: area) == derecha3)
        #expect(layout.neighbour(of: snapped(arriba), towards: .right, in: area) == centro)
    }

    /// The tie-break is reading order and not file order. The same five zones
    /// with the right-hand pair written bottom first still send → to the top.
    @Test("The topmost wins the tie, however the file orders them")
    func topmostNotFirstInTheFile() {
        var reversed = layout
        reversed.zones.swapAt(derecha3, derecha4)

        #expect(reversed.zones[layout.neighbour(of: snapped(centro), towards: .right, in: area)!].name
                == "Derecha 4", "sanity: the indices moved")
        #expect(reversed.zones[reversed.neighbour(of: snapped(centro), towards: .right, in: area)!].name
                == "Derecha 3")
    }

    /// And the same rule turned ninety degrees: a wide zone above two zones
    /// side by side goes to the left one on ↓.
    @Test("The leftmost wins the tie for ↑ and ↓")
    func leftmostForVerticalMoves() {
        let rows = Layout(name: "Rows", zones: [
            Zone(name: "Top",          x: 0,   y: 0,   width: 1,   height: 0.5),
            Zone(name: "Bottom Right", x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            Zone(name: "Bottom Left",  x: 0,   y: 0.5, width: 0.5, height: 0.5),
        ])
        let top = rows.frame(of: rows.zones[0], in: area)

        #expect(rows.neighbour(of: top, towards: .down, in: area) == 2)
    }

    /// The cover test is against frames, not hit regions: with a margin the
    /// window in the column is shorter than the column's hit region and would
    /// otherwise cover neither right-hand zone — and → would fall back to the
    /// centre line and the lower zone, which is the report all over again.
    @Test("A margin does not bring the bottom zone back")
    func withAMargin() {
        var framed = layout
        framed.margin = 20
        let column = framed.frame(of: framed.zones[centro], in: area)

        #expect(framed.neighbour(of: column, towards: .right, in: area) == derecha3)
    }

    @Test("↑ and ↓ from a full-height zone go nowhere")
    func nothingAboveOrBelowAColumn() {
        #expect(layout.neighbour(of: snapped(centro), towards: .up, in: area) == nil)
        #expect(layout.neighbour(of: snapped(centro), towards: .down, in: area) == nil)
    }

    /// The zone the window is in is never the answer. Its near edge is on the
    /// wrong side of the window's middle, which is what "all of it past the
    /// middle" is for.
    @Test("No arrow ever sends a window into the zone it is already in")
    func neverTheSameZone() {
        for index in layout.zones.indices {
            for direction in Direction.allCases {
                #expect(layout.neighbour(of: snapped(index), towards: direction, in: area) != index)
            }
        }
    }

    /// A window nobody has snapped, sitting mostly in the middle and hanging a
    /// little way into the top-left zone. → goes right of where it is, and
    /// ← goes to the zone it is hanging into — its near edge is past the
    /// window's middle, even though the window overlaps it.
    @Test("A floating window moves relative to where it is, not to a zone it is in")
    func aFloatingWindow() {
        let floating = CGRect(x: 1000, y: 200, width: 1200, height: 800)

        #expect(layout.neighbour(of: floating, towards: .right, in: area) == derecha3)
        #expect(layout.neighbour(of: floating, towards: .left, in: area) == arriba)
        // It hangs 280 points into the left column, and the bottom-left zone is
        // entirely below its middle — and it is still not "below" the window,
        // because it is not across from its middle. This is the case that
        // decided the rule.
        #expect(layout.neighbour(of: floating, towards: .down, in: area) == nil)
    }

    /// A small window near the bottom of the middle column: → is the *lower*
    /// right-hand zone, because that is the one that shares its height.
    @Test("A small window goes to the zone beside it, not the first one in the column")
    func aSmallWindowLowDown() {
        let small = CGRect(x: 2000, y: 1100, width: 400, height: 300)

        #expect(layout.neighbour(of: small, towards: .right, in: area) == derecha4)
        #expect(layout.neighbour(of: small, towards: .left, in: area) == abajo)
    }

    /// A window filling the screen — what ↩ leaves behind — covers every zone,
    /// so it is beside all of them, and every arrow is answered by reading
    /// order: the top-left for ← and ↑, the top-right for →, the bottom-left
    /// for ↓. Four keys out of a maximised window rather than two, and none of
    /// them a surprise once the rule is known.
    @Test("A maximised window is beside every zone, and reading order answers each arrow")
    func outOfMaximised() {
        let everything = layout.frame(of: Layout.maximised, in: area)

        #expect(layout.neighbour(of: everything, towards: .left, in: area) == arriba)
        #expect(layout.neighbour(of: everything, towards: .right, in: area) == derecha3,
                "it covers both right-hand zones, and the top one wins")
        #expect(layout.neighbour(of: everything, towards: .up, in: area) == arriba)
        #expect(layout.neighbour(of: everything, towards: .down, in: area) == abajo)
    }

    /// The property the whole feature was asked for. The answer is computed
    /// from the frame and the layout and nothing else, so the same frame gets
    /// the same answer however many times it is asked and whatever was asked
    /// before it.
    @Test("The same position gives the same answer, every time, in any order")
    func deterministic() {
        let frames = [snapped(arriba), snapped(centro), CGRect(x: 1000, y: 200, width: 1200, height: 800)]
        let first = frames.map { frame in
            Direction.allCases.map { layout.neighbour(of: frame, towards: $0, in: area) }
        }
        // Ask again backwards, interleaved, and after a different question.
        for (frame, expected) in zip(frames, first).reversed() {
            _ = layout.neighbour(of: snapped(derecha4), towards: .left, in: area)
            let again = Direction.allCases.map { layout.neighbour(of: frame, towards: $0, in: area) }
            #expect(again == expected)
        }
    }

    @Test("The zone a window is in is the smallest one under its middle")
    func theZoneItIsIn() {
        #expect(layout.zoneIndex(holding: snapped(derecha4), in: area) == derecha4)
        #expect(layout.zoneIndex(holding: CGRect(x: 1000, y: 200, width: 1200, height: 800), in: area)
                == centro)
        #expect(layout.zoneIndex(holding: layout.frame(of: Layout.maximised, in: area), in: area)
                == centro, "the middle of the screen is in the middle column")
    }

    /// Layouts are allowed to overlap, and the rules have to hold up when they
    /// do: a small zone floating over a big one is reachable from across it,
    /// not from anywhere, and the big one is never "beside" the small one.
    @Test("A small zone on top of a big one is reached from across it, and the big one is never beside it")
    func overlappingZones() {
        let stacked = Layout(name: "Stacked", zones: [
            Zone(name: "Everything", x: 0,   y: 0,   width: 1,   height: 1),
            Zone(name: "Corner",     x: 0.8, y: 0.8, width: 0.2, height: 0.2),
        ])
        let corner = stacked.frame(of: stacked.zones[1], in: area)
        let acrossFromIt = CGRect(x: 2000, y: 1100, width: 800, height: 300)
        let higherUp = CGRect(x: 2000, y: 500, width: 800, height: 400)

        #expect(stacked.neighbour(of: acrossFromIt, towards: .right, in: area) == 1)
        #expect(stacked.neighbour(of: higherUp, towards: .right, in: area) == nil,
                "the corner is diagonally below it, and diagonals were left out on purpose")
        #expect(stacked.neighbour(of: corner, towards: .left, in: area) == nil,
                "the big zone surrounds the corner; it is not to its left")
    }
}

@Suite("The keys the file names")
struct ChordTests {

    @Test("control+option reads, in either order and with spaces")
    func reads() {
        #expect(Chord("control+option") == .standard)
        #expect(Chord("option+control") == .standard)
        #expect(Chord(" option + control ") == .standard)
        #expect(Chord("command+shift+option")?.keys == [.command, .shift, .option])
    }

    @Test("A key that is not one of the four is refused")
    func unknownKeys() {
        #expect(Chord("control+hyper") == nil)
        #expect(Chord("ctrl+alt") == nil)
    }

    @Test("It prints the way the keyboard does, whatever order it was written in")
    func symbol() {
        #expect(Chord("option+control")?.symbol == "⌃⌥")
        #expect(Chord("command+shift")?.symbol == "⇧⌘")
    }
}
