import Foundation
import Testing
@testable import Zonas

@Suite("Keeping the layout in memory")
struct LayoutStoreTests {

    private let twoZones = """
    {
      "name": "Two",
      "zones": [
        { "name": "Left",  "x": 0,   "y": 0, "width": 0.5, "height": 1 },
        { "name": "Right", "x": 0.5, "y": 0, "width": 0.5, "height": 1 }
      ]
    }
    """

    @Test("With no file at all, the built-in layout is what you get")
    func startsFromTheBuiltInLayout() throws {
        try inTemporaryDirectory { dir in
            let store = LayoutStore(url: dir.appendingPathComponent("zonas.json"))

            #expect(store.layout == .threeColumns)
        }
    }

    @Test("A file that is there is read at startup")
    func readsTheFile() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json")
            try Data(twoZones.utf8).write(to: url)

            let store = LayoutStore(url: url)

            #expect(store.layout.name == "Two")
            #expect(store.layout.zones.count == 2)
        }
    }

    /// The test §3c could not have: it needs a file that can be broken on
    /// purpose, which needs a store that can be pointed somewhere harmless.
    @Test("A broken file leaves the layout that was working alone")
    func abrokenFileKeepsTheLastGoodLayout() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json")
            try Data(twoZones.utf8).write(to: url)
            let store = LayoutStore(url: url)
            let before = store.layout

            try Data("{ \"name\": \"Two\", \"zones\": [ ,, ] }".utf8).write(to: url)
            let reloaded = store.reload()

            #expect(reloaded == .failed)
            #expect(store.layout == before, "a typo took the working zones with it")
        }
    }

    @Test("An edit made outside the app is picked up on reload")
    func reloadSeesAnExternalEdit() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json")
            try Data(twoZones.utf8).write(to: url)
            let store = LayoutStore(url: url)

            try Data(#"{ "name": "One", "zones": [ { "name": "All", "x": 0, "y": 0, "width": 1, "height": 1 } ] }"#.utf8)
                .write(to: url)

            #expect(store.reload() == .changed)
            #expect(store.layout.name == "One")
        }
    }

    @Test("The first launch writes a file, and no launch after that touches it")
    func createIfMissingOnlyCreates() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas").appendingPathComponent("zonas.json")

            LayoutStore(url: url).createIfMissing()
            #expect(FileManager.default.fileExists(atPath: url.path))

            // Whatever is in there now belongs to the user, typos included.
            try Data("edited by hand, and broken".utf8).write(to: url)
            LayoutStore(url: url).createIfMissing()

            #expect(try String(contentsOf: url, encoding: .utf8) == "edited by hand, and broken")
        }
    }
}

@Suite("Finding the zone under the cursor")
struct HitTestingTests {

    private let area = CGRect(x: 100, y: 50, width: 5120, height: 1440)

    @Test("A point in the middle of a zone finds it")
    func findsTheZone() {
        let hit = Layout.threeColumns.zone(under: CGPoint(x: 2660, y: 700), in: area)

        #expect(hit?.name == "Center")
    }

    /// Comparing rectangles used to be how the overlay knew which zone to
    /// highlight, and duplicating a zone is a thing a config file invites you to
    /// do. The index tells the two apart; a rectangle never could.
    @Test("Two zones with the same geometry are still told apart")
    func duplicateZonesAreDistinguishable() {
        let layout = Layout(name: "Duplicated", zones: [
            Zone(name: "Left",  x: 0, y: 0, width: 0.5, height: 1),
            Zone(name: "Left again", x: 0, y: 0, width: 0.5, height: 1),
        ])

        let index = layout.zoneIndex(under: CGPoint(x: 500, y: 700), in: area)

        // The first one wins, because `min(by:)` keeps the earlier of two equals
        // — what matters is that exactly one of them does.
        #expect(index == 0)
    }

    /// The gap is something you see, not something you can fall into. If the
    /// inset ever moves into `rect(in:)` this is the test that fails, and it
    /// fails for the right reason: eight points of screen where a drop does
    /// nothing at all.
    @Test("The visible gap between two zones is still part of one of them")
    func theGapIsNotAHole() {
        let boundary = Layout.threeColumns.zones[0].rect(in: area).maxX

        for offset in [-Layout.defaultGap / 2, -1, 0, 1, Layout.defaultGap / 2] {
            let hit = Layout.threeColumns.zone(under: CGPoint(x: boundary + offset, y: 700),
                                               in: area)
            #expect(hit != nil, "nothing under x = boundary \(offset >= 0 ? "+" : "")\(offset)")
        }
    }

    /// What makes a layout with a big background zone and smaller ones on top
    /// usable. Without it the big one eats every target.
    @Test("When zones overlap the smallest one wins")
    func theSmallestOverlappingZoneWins() {
        let layout = Layout(name: "Overlapping", zones: [
            Zone(name: "Everything", x: 0,    y: 0,    width: 1,   height: 1),
            Zone(name: "Corner",     x: 0.75, y: 0.75, width: 0.25, height: 0.25),
        ])

        #expect(layout.zone(under: CGPoint(x: 5000, y: 1400), in: area)?.name == "Corner")
        #expect(layout.zone(under: CGPoint(x: 200,  y: 100),  in: area)?.name == "Everything")
    }

    @Test("A point outside every zone finds nothing")
    func findsNothingOutside() {
        let layout = Layout(name: "Half", zones: [
            Zone(name: "Top", x: 0, y: 0, width: 1, height: 0.5),
        ])

        #expect(layout.zone(under: CGPoint(x: 2000, y: 1400), in: area) == nil)
    }
}

/// Several zones taken together as one.
///
/// The layout is this desk's: four zones, a quarter-width column split in two on
/// the left, a half in the middle, a quarter on the right.
@Suite("Covering several zones at once")
struct SpanTests {

    private let layout = Layout(name: "Tres columnas", zones: [
        Zone(name: "Izquierda Arriba", x: 0,    y: 0,   width: 0.25, height: 0.5),
        Zone(name: "Izquierda Abajo",  x: 0,    y: 0.5, width: 0.25, height: 0.5),
        Zone(name: "Centro",           x: 0.25, y: 0,   width: 0.5,  height: 1),
        Zone(name: "Derecha",          x: 0.75, y: 0,   width: 0.25, height: 1),
    ])
    private let area = CGRect(x: 0, y: 33, width: 1728, height: 1084)

    @Test("Nothing selected spans nothing")
    func emptyIsNil() {
        #expect(layout.union(of: []) == nil)
    }

    /// The ordinary gesture goes through the same call, so it has to come back
    /// completely untouched — same name, same fractions, and therefore the same
    /// rectangle as before any of this existed.
    @Test("One zone is itself, exactly")
    func oneIsItself() {
        #expect(layout.union(of: [2]) == layout.zones[2])
        #expect(layout.union(of: [2]).map { layout.frame(of: $0, in: area) }
                == layout.frame(of: layout.zones[2], in: area))
    }

    @Test("Two zones stacked vertically become the column they make up")
    func twoStackedBecomeAColumn() {
        let union = layout.union(of: [0, 1])

        #expect(union?.x == 0)
        #expect(union?.y == 0)
        #expect(union?.width == 0.25)
        #expect(union?.height == 1)
    }

    @Test("Two side by side become the width of both")
    func twoSideBySideBecomeWider() {
        let union = layout.union(of: [2, 3])

        #expect(union?.x == 0.25)
        #expect(union?.width == 0.75)
        #expect(union?.height == 1)
    }

    /// The bounding box, so a selection with a hole in it swallows the hole.
    /// Choosing the top-left quarter and the right-hand column covers the middle
    /// column and the bottom-left quarter as well, and that is the intended
    /// answer rather than a bug: the alternative is explaining a contiguity rule
    /// to somebody who is mid-drag with two keys held down.
    @Test("A selection with a hole in it covers the hole")
    func theBoundingBoxSwallowsTheGap() {
        let union = layout.union(of: [0, 3])

        #expect(union?.x == 0)
        #expect(union?.y == 0)
        #expect(union?.width == 1)
        #expect(union?.height == 1)
    }

    /// Not the order they were gathered in. The same three zones have to produce
    /// the same label however the cursor swept across them, or the log and the
    /// overlay would disagree with themselves between two identical drags.
    @Test("The name is joined in file order, not in the order they were visited")
    func theNameIsDeterministic() {
        #expect(layout.union(of: [3, 0, 2])?.name == layout.union(of: [0, 2, 3])?.name)
        #expect(layout.union(of: [2, 0])?.name == "Izquierda Arriba + Centro")
    }

    /// The point of the whole design: a union is an ordinary `Zone`, so the gap
    /// and margin rule applies to it once, at its outside edges, and the gaps
    /// that used to be *between* the zones are gone. A window given "Izquierda
    /// Arriba + Izquierda Abajo" must be one window as tall as the screen, not
    /// two half-height ones with air in the middle.
    @Test("The gaps inside a span disappear, and only the outer ones remain")
    func theInnerGapsGoAway() {
        let span = layout.union(of: [0, 1])!
        let separately = layout.frame(of: layout.zones[0], in: area).height
            + layout.frame(of: layout.zones[1], in: area).height

        let spanned = layout.frame(of: span, in: area)

        #expect(spanned.height > separately)
        #expect(spanned.height == area.height)          // margin 0, both edges touch
        #expect(spanned.width == layout.frame(of: layout.zones[0], in: area).width)
    }

    /// An index that is not in the layout cannot crash the drop path. It can
    /// only get there if the file changes mid-drag, which the snapshot is
    /// supposed to prevent — "supposed to" being the reason this is tested.
    @Test("An index that is not in the layout is ignored")
    func strayIndicesAreIgnored() {
        #expect(layout.union(of: [2, 99]) == layout.zones[2])
        #expect(layout.union(of: [99]) == nil)
    }
}
