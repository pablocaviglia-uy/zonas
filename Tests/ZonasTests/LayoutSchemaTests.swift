import Foundation
import Testing
@testable import Zonas

private func layout(_ source: String) throws -> Layout {
    try Layout(LayoutSyntax.parse(source))
}

@Suite("Turning the tree into a layout")
struct LayoutSchemaTests {

    @Test("An ordinary layout reads")
    func readsALayout() throws {
        let result = try layout("""
        {
          name: "Three Columns",
          zones: [
            { name: "Left",   x: 0,    y: 0, width: 0.25, height: 1 },
            { name: "Center", x: 0.25, y: 0, width: 0.5,  height: 1 },
          ],
        }
        """)

        #expect(result.name == "Three Columns")
        #expect(result.zones == [
            Zone(name: "Left",   x: 0,    y: 0, width: 0.25, height: 1),
            Zone(name: "Center", x: 0.25, y: 0, width: 0.5,  height: 1),
        ])
    }

    /// The starting file and the built-in layout have to stay the same thing,
    /// or the app behaves one way today and another after a restart.
    @Test("It reads the starting file as the built-in layout")
    func itReadsTheSeed() throws {
        #expect(try layout(LayoutFile.seed) == .threeColumns)
    }

    /// Keys from a newer version of the app must not stop an older one from
    /// reading the file — and the tree still has them, so a write gives them
    /// back untouched.
    @Test("Keys it does not recognise are ignored, not rejected")
    func unknownKeysAreIgnored() throws {
        let result = try layout("""
        {
          version: 7,
          name: "From the future",
          hooks: { onSnap: "say hello" },
          zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1, opacity: 0.5 } ],
        }
        """)

        #expect(result.name == "From the future")
        #expect(result.zones.count == 1)
    }
}

@Suite("Fractions of the screen")
struct FractionTests {

    @Test("Plain decimals read")
    func decimals() throws {
        let zones = try layout("""
        { name: "L", zones: [ { name: "A", x: .25, y: 0, width: 0.5, height: 1 } ] }
        """).zones

        #expect(zones[0].x == 0.25)
        #expect(zones[0].width == 0.5)
    }

    /// The reason ratios exist. Written as 0.3333 these three leave a sliver on
    /// the right edge that is invisible in the file and maddening on screen.
    @Test("Three thirds written as ratios add up to exactly one")
    func thirdsAreExact() throws {
        let zones = try layout("""
        { name: "Ultrawide", zones: [
            { name: "A", x: 0,     y: 0, width: "1/3", height: 1 },
            { name: "B", x: "1/3", y: 0, width: "1/3", height: 1 },
            { name: "C", x: "2/3", y: 0, width: "1/3", height: 1 },
        ] }
        """).zones

        let rightEdge = zones.map { $0.x + $0.width }.max()

        #expect(rightEdge == 1.0)
        #expect(zones[1].x == 1.0 / 3.0)
    }

    @Test("Percentages read")
    func percentages() throws {
        let zones = try layout("""
        { name: "L", zones: [ { name: "A", x: "25%", y: 0, width: "50%", height: 1 } ] }
        """).zones

        #expect(zones[0].x == 0.25)
        #expect(zones[0].width == 0.5)
    }

    @Test("Nonsense in a number's place is refused")
    func nonsenseIsRefused() {
        #expect(Zone.fraction(of: .string("half")) == nil)
        #expect(Zone.fraction(of: .string("1/0")) == nil)
        #expect(Zone.fraction(of: .bool(true)) == nil)
        #expect(Zone.fraction(of: .null) == nil)
    }
}

@Suite("Saying what is wrong with a layout, and where")
struct LayoutSchemaErrorTests {

    private func error(in source: String) throws -> LayoutSchemaError? {
        #expect(throws: LayoutSchemaError.self) { try layout(source) }
    }

    /// §5: the name is the handle in the file. Two zones called "Left" is
    /// already something you can see on screen; this says so instead of letting
    /// you find out later.
    @Test("Two zones with the same name name both lines")
    func duplicateNames() throws {
        let problem = try error(in: """
        {
          name: "L",
          zones: [
            { name: "Left",  x: 0,   y: 0, width: 0.5, height: 1 },
            { name: "Right", x: 0.5, y: 0, width: 0.5, height: 1 },
            { name: "Left",  x: 0,   y: 0, width: 0.5, height: 1 },
          ],
        }
        """)

        #expect(problem?.line == 6)
        #expect(problem?.description == #"line 6: there is already a zone called "Left", on line 4"#)
    }

    @Test("A missing width points at the zone")
    func missingWidth() throws {
        let problem = try error(in: """
        {
          name: "L",
          zones: [
            { name: "Left", x: 0, y: 0, height: 1 },
          ],
        }
        """)

        #expect(problem?.line == 4)
        #expect(problem?.message == "this zone has no width")
    }

    @Test("A width that is not a number points at the width")
    func unreadableWidth() throws {
        let problem = try error(in: """
        {
          name: "L",
          zones: [
            {
              name: "Left",
              x: 0, y: 0,
              width: "half",
              height: 1,
            },
          ],
        }
        """)

        #expect(problem?.line == 7)
        #expect(problem?.message.contains("\"1/4\"") == true)
    }

    @Test("A zone with no area is refused")
    func emptyZone() throws {
        let problem = try error(in: """
        { name: "L", zones: [
          { name: "Nothing", x: 0, y: 0, width: 0, height: 1 },
        ] }
        """)

        #expect(problem?.message == "a zone needs a width and a height above zero")
    }

    @Test("A file with no zones at all says so")
    func noZones() throws {
        #expect(try error(in: #"{ name: "L" }"#)?.message == "the layout needs a list of zones")
    }

    @Test("A file that is not an object says so")
    func notAnObject() throws {
        #expect(try error(in: "[1, 2, 3]")?.message == "the file has to hold one object, in braces")
    }

    /// The whole point of carrying the line through: the message a user sees
    /// has to be somewhere they can go.
    @Test("Every message reads as a place plus a problem")
    func messagesAreActionable() {
        let problem = LayoutSchemaError(line: 12, message: "this zone has no width")

        #expect("\(problem)" == "line 12: this zone has no width")
    }
}
