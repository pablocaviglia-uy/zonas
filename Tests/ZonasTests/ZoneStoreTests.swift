import Foundation
import Testing
@testable import Zonas

@Suite("Keeping the layout in memory")
struct ZoneStoreTests {

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
            let store = ZoneStore(url: dir.appendingPathComponent("zonas.json"))

            #expect(store.layout == .threeColumns)
        }
    }

    @Test("A file that is there is read at startup")
    func readsTheFile() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json")
            try Data(twoZones.utf8).write(to: url)

            let store = ZoneStore(url: url)

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
            let store = ZoneStore(url: url)
            let before = store.layout

            try Data("{ \"name\": \"Two\", \"zones\": [ ,, ] }".utf8).write(to: url)
            let reloaded = store.reload()

            #expect(reloaded == false)
            #expect(store.layout == before, "a typo took the working zones with it")
        }
    }

    @Test("An edit made outside the app is picked up on reload")
    func reloadSeesAnExternalEdit() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json")
            try Data(twoZones.utf8).write(to: url)
            let store = ZoneStore(url: url)

            try Data(#"{ "name": "One", "zones": [ { "name": "All", "x": 0, "y": 0, "width": 1, "height": 1 } ] }"#.utf8)
                .write(to: url)

            #expect(store.reload() == true)
            #expect(store.layout.name == "One")
        }
    }

    @Test("The first launch writes a file, and no launch after that touches it")
    func createIfMissingOnlyCreates() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas").appendingPathComponent("zonas.json")

            ZoneStore(url: url).createIfMissing()
            #expect(FileManager.default.fileExists(atPath: url.path))

            // Whatever is in there now belongs to the user, typos included.
            try Data("edited by hand, and broken".utf8).write(to: url)
            ZoneStore(url: url).createIfMissing()

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

        #expect(hit?.zone.name == "Center")
    }

    /// The gap is something you see, not something you can fall into. If the
    /// inset ever moves into `rect(in:)` this is the test that fails, and it
    /// fails for the right reason: eight points of screen where a drop does
    /// nothing at all.
    @Test("The visible gap between two zones is still part of one of them")
    func theGapIsNotAHole() {
        let boundary = Layout.threeColumns.zones[0].rect(in: area).maxX

        for offset in [-Zone.gap / 2, -1, 0, 1, Zone.gap / 2] {
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

        #expect(layout.zone(under: CGPoint(x: 5000, y: 1400), in: area)?.zone.name == "Corner")
        #expect(layout.zone(under: CGPoint(x: 200,  y: 100),  in: area)?.zone.name == "Everything")
    }

    @Test("A point outside every zone finds nothing")
    func findsNothingOutside() {
        let layout = Layout(name: "Half", zones: [
            Zone(name: "Top", x: 0, y: 0, width: 1, height: 0.5),
        ])

        #expect(layout.zone(under: CGPoint(x: 2000, y: 1400), in: area) == nil)
    }
}
