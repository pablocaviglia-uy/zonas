import Foundation
import Testing
@testable import Zonas

/// The laptop screen, placed above and to the left of the main display so that
/// anything assuming the desktop starts at the origin fails here rather than on
/// somebody's second monitor. CG coordinates: y grows downwards, so the top of
/// the screen is `minY`.
private let screen = CGRect(x: -1512, y: -100, width: 1512, height: 982)

/// What is left of it: a 37-point menu bar off the top and a Dock off the
/// bottom. Every zone in the file is a fraction of *this*.
private let area = CGRect(x: -1512, y: -63, width: 1512, height: 850)

private let layout = Layout(name: "Two", zones: [
    Zone(name: "Top",    x: 0, y: 0,   width: 1, height: 0.5),
    Zone(name: "Bottom", x: 0, y: 0.5, width: 1, height: 0.5),
])

@Suite("The band along the top edge")
struct MaximiseBandTests {

    @Test("It reaches from the top of the screen to the setting's depth into the zones")
    func theBandsRectangle() {
        let band = layout.maximiseBand(of: screen, usable: area)

        #expect(band?.minY == screen.minY, "it has to start at the top of the screen")
        #expect(band?.maxY == area.minY + 24, "and end 24 points into the usable area")
        #expect(band?.height == 61, "37 points of menu bar plus the 24 of the setting")
    }

    /// The reason those 37 points are in it at all. macOS stops the window when
    /// its title bar meets the menu bar and does not stop the pointer, so this
    /// is where the cursor ends up when somebody throws a window at the top of
    /// the screen — and it is a strip no zone can ever cover, because zones are
    /// fractions of what is left after the menu bar.
    @Test("The pointer over the menu bar is inside it")
    func theMenuBarCounts() {
        let band = layout.maximiseBand(of: screen, usable: area)

        #expect(band?.contains(CGPoint(x: -700, y: screen.minY + 2)) == true)
        #expect(layout.zoneIndex(under: CGPoint(x: -700, y: screen.minY + 2), in: area) == nil,
                "no zone reaches up here, which is what makes the strip free")
    }

    @Test("One point below it is not in it")
    func itEndsWhereItSaysItDoes() {
        let band = layout.maximiseBand(of: screen, usable: area)

        #expect(band?.contains(CGPoint(x: -700, y: area.minY + 23)) == true)
        #expect(band?.contains(CGPoint(x: -700, y: area.minY + 25)) == false)
    }

    /// It spans the screen and not the usable area, so a Dock on the left does
    /// not carve a dead corner out of the top edge.
    @Test("It covers the whole width of the screen, Dock included")
    func itSpansTheScreen() {
        let narrowed = CGRect(x: area.minX + 80, y: area.minY,
                              width: area.width - 80, height: area.height)

        let band = layout.maximiseBand(of: screen, usable: narrowed)

        #expect(band?.minX == screen.minX)
        #expect(band?.width == screen.width)
        #expect(band?.contains(CGPoint(x: screen.minX + 4, y: screen.minY + 4)) == true)
    }

    @Test("Zero turns it off, and there is then no band at all")
    func zeroTurnsItOff() {
        var off = layout
        off.maximise = 0

        #expect(off.maximiseBand(of: screen, usable: area) == nil)
    }

    /// A file may say something silly, and this says what happens then rather
    /// than pretending it cannot. It is the same answer `check` gives a zone
    /// hanging off the edge of the screen: legal, printed, and the author's
    /// business. The number is in `zonas check`'s first line for exactly this.
    @Test("A band deeper than the screen is honoured, not second-guessed")
    func anAbsurdBandIsStillABand() {
        var swallowed = layout
        swallowed.maximise = 5000

        let band = swallowed.maximiseBand(of: screen, usable: area)

        #expect(band?.contains(CGPoint(x: -700, y: area.maxY - 1)) == true)
    }

    /// The band is a hit region — `Zone.rect`'s side of the family — and the
    /// rectangle the window is given has nothing to do with it. Confusing the
    /// two is §3e, and here the two are 61 points and the whole screen.
    @Test("What the window gets is the usable area, not the band")
    func theBandIsNotTheFrame() {
        let target = layout.target(of: .maximised)

        #expect(target == Layout.maximised)
        #expect(target.map { layout.frame(of: $0, in: area) } == area)
    }

    @Test("The margin is the only thing taken off it")
    func theMarginApplies() {
        var framed = layout
        framed.margin = 20

        #expect(framed.target(of: .maximised).map { framed.frame(of: $0, in: area) }
                == area.insetBy(dx: 20, dy: 20))
    }
}

@Suite("What a drag has chosen")
struct SelectionTests {

    /// The path that existed before any of this: zones, by index, unioned. It
    /// is here because `target` replaced `union` at both call sites, and the
    /// ordinary drop is the one that must not have changed.
    @Test("Zones still resolve to their union, exactly as before")
    func zonesAreUnchanged() {
        #expect(layout.target(of: .zones([0, 1])) == layout.union(of: [0, 1]))
        #expect(layout.target(of: .zones([1])) == layout.zones[1])
    }

    @Test("Nothing chosen resolves to nothing, and nothing snaps")
    func emptyIsNil() {
        #expect(layout.target(of: .zones([])) == nil)
    }

    /// What the overlay asks, to know which boxes it would otherwise draw
    /// twice. Maximising covers no zone in particular — that is the point of it
    /// not being `.zones` holding every index — so the layout is left undrawn
    /// and there is one rectangle on screen.
    @Test("Maximising covers none of the file's zones")
    func maximisingIsNotZones() {
        #expect(Selection.maximised.gathered.isEmpty)
        #expect(Selection.zones([0, 1]).gathered == [0, 1])
        #expect(Selection.maximised != .zones([0, 1]))
    }
}
