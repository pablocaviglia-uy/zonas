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

@Suite("Settings read from the file")
struct DefaultsTests {

    private func layout(_ defaults: String) throws -> Layout {
        try Layout(LayoutSyntax.parse("""
        {
          version: 1,
          defaults: \(defaults),
          name: "L",
          zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ],
        }
        """))
    }

    @Test("With no defaults block, the built-in values apply")
    func theBuiltInValues() throws {
        let result = try Layout(LayoutSyntax.parse(#"{ name: "L", zones: [] }"#))

        #expect(result.gap == 8)
        #expect(result.margin == 0)
        #expect(result.modifier == .shift)
    }

    @Test("gap, margin and modifier are read")
    func allThreeAreRead() throws {
        let result = try layout(#"{ gap: 12, margin: 20, modifier: "control" }"#)

        #expect(result.gap == 12)
        #expect(result.margin == 20)
        #expect(result.modifier == .control)
    }

    @Test("Setting only one leaves the others alone")
    func partialDefaults() throws {
        let result = try layout("{ gap: 0 }")

        #expect(result.gap == 0)
        #expect(result.margin == Layout.defaultMargin)
        #expect(result.modifier == .shift)
    }

    @Test("Every modifier the file can name maps to a real key")
    func everyModifier() throws {
        for modifier in Modifier.allCases {
            let result = try layout("{ modifier: \"\(modifier.rawValue)\" }")

            #expect(result.modifier == modifier)
            #expect(!result.modifier.symbol.isEmpty)
        }
    }

    /// A typo in a modifier has to name the alternatives. "invalid value" and a
    /// line number still leaves you guessing what to type instead.
    @Test("A modifier that is not a key lists the ones that are")
    func anUnknownModifier() throws {
        let problem = #expect(throws: LayoutSchemaError.self) {
            try layout(#"{ modifier: "hyper" }"#)
        }

        #expect(problem?.message.contains("\"shift\"") == true)
        #expect(problem?.message.contains("\"command\"") == true)
        #expect(problem?.line == 3)
    }

    @Test("A negative gap is refused")
    func anegativeGap() throws {
        let problem = #expect(throws: LayoutSchemaError.self) {
            try layout("{ gap: -4 }")
        }

        #expect(problem?.message.contains("zero or more") == true)
    }

    @Test("A key in defaults that this version does not know is ignored")
    func unknownSettingsAreIgnored() throws {
        let result = try layout(#"{ gap: 4, animation: "fade" }"#)

        #expect(result.gap == 4)
    }

    @Test("defaults has to be an object")
    func defaultsMustBeAnObject() throws {
        let problem = #expect(throws: LayoutSchemaError.self) { try layout("8") }

        #expect(problem?.message.contains("in braces") == true)
    }
}

/// The applications the file says to leave alone.
@Suite("The ignore list")
struct IgnoreListTests {

    private let oneZone = """
      zones: [{ name: "All", x: 0, y: 0, width: 1, height: 1 }],
    """

    private func withIgnore(_ entry: String) throws -> Layout {
        try layout("{ name: \"L\", \(oneZone) ignore: \(entry) }")
    }

    @Test("A layout with no ignore list ignores nothing")
    func absentMeansEmpty() throws {
        let result = try layout("{ name: \"L\", \(oneZone) }")

        #expect(result.ignored.isEmpty)
        #expect(result.ignores("com.apple.Safari") == false)
    }

    @Test("Bundle identifiers are read and matched exactly")
    func identifiersMatch() throws {
        let result = try withIgnore(#"["com.apple.Safari", "com.apple.ActivityMonitor"]"#)

        #expect(result.ignored == ["com.apple.Safari", "com.apple.ActivityMonitor"])
        #expect(result.ignores("com.apple.Safari"))
        #expect(result.ignores("com.apple.ActivityMonitor"))
    }

    /// Exact, and that is the whole rule. A prefix that happens to match must
    /// not take the app with it — `com.apple.Safari` is not `com.apple`, and
    /// somebody who wrote the shorter one is going to be surprised either way,
    /// so it had better be surprised in the direction of doing nothing.
    @Test("Nothing but an exact identifier matches")
    func onlyExactMatches() throws {
        let result = try withIgnore(#"["com.apple.Safari"]"#)

        #expect(result.ignores("com.apple") == false)
        #expect(result.ignores("com.apple.SafariTechnologyPreview") == false)
        #expect(result.ignores("Safari") == false)
        #expect(result.ignores("COM.APPLE.SAFARI") == false)
    }

    /// A process with no bundle identifier — the Android emulator on this
    /// machine — cannot be excluded, and must not be excluded by accident
    /// either.
    @Test("A process with no identifier is never in the list")
    func noIdentifierIsNeverIgnored() throws {
        let result = try withIgnore(#"["com.apple.Safari"]"#)

        #expect(result.ignores(nil) == false)
    }

    /// The point of §6's bet, one level down: the file describes the world,
    /// including the parts of it that are not installed on the machine reading
    /// the file.
    @Test("An app that is not installed is not an error")
    func uninstalledAppsAreFine() throws {
        #expect(try withIgnore(#"["com.example.NotHere"]"#).ignores("com.example.NotHere"))
    }

    @Test("ignore has to be a list")
    func mustBeAList() throws {
        let problem = #expect(throws: LayoutSchemaError.self) {
            try withIgnore(#""com.apple.Safari""#)
        }

        #expect(problem?.message.contains("in brackets") == true)
    }

    @Test("An entry that is not text names its own line")
    func entriesMustBeText() throws {
        let problem = #expect(throws: LayoutSchemaError.self) {
            try layout("""
            {
              name: "L",
              zones: [{ name: "All", x: 0, y: 0, width: 1, height: 1 }],
              ignore: [
                "com.apple.Safari",
                42,
              ],
            }
            """)
        }

        #expect(problem?.line == 6)
        #expect(problem?.message.contains("in quotes") == true)
    }

    @Test("An empty identifier is refused")
    func emptyEntriesAreRefused() throws {
        #expect(throws: LayoutSchemaError.self) { try withIgnore(#"[""]"#) }
    }

    /// Rule 4, from the other side: a key the editor never touches has to come
    /// back out of the writer exactly as it went in, comments and all.
    @Test("It survives a write that only changed the zones")
    func itSurvivesTheWriter() throws {
        let source = """
        {
          name: "L",
          // the ones that are the wrong shape for a layout
          ignore: [
            "com.apple.ActivityMonitor",  // too small to be worth a zone
          ],
          zones: [{ name: "All", x: 0, y: 0, width: 1, height: 1 }],
        }
        """
        var document = try EditorDocument(layout(source))
        let cut = document.split(rid: document.zones[0].rid, at: 0.5, .vertical, minimum: 0.01)
        #expect(cut)

        let written = try LayoutWriter.apply(document, to: source)

        #expect(written.contains(#""com.apple.ActivityMonitor""#))
        #expect(written.contains("// too small to be worth a zone"))
        #expect(try layout(written).ignored == ["com.apple.ActivityMonitor"])
    }
}
