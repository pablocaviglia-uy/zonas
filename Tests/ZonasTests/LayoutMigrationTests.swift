import Foundation
import Testing
@testable import Zonas

/// A file as the pre-1.0 app wrote it: no version, `.json`, and the UUIDs it
/// used to put in whether you wanted them or not.
private let v0 = """
{
  "name" : "Tres columnas",
  "zones" : [
    {
      "height" : 1,
      "id" : "B6D50A32-8418-467E-9BB2-A9724216EE7F",
      "name" : "Izquierda",
      "width" : 0.25,
      "x" : 0,
      "y" : 0
    },
    {
      "height" : 1,
      "id" : "732A2E2E-0363-4B88-9CFD-52B933C2EC41",
      "name" : "Centro",
      "width" : 0.75,
      "x" : 0.25,
      "y" : 0
    }
  ]
}
"""

@Suite("Bringing a pre-1.0 layout across")
struct LayoutMigrationTests {

    private func migrating(_ contents: String = v0,
                           _ body: (_ legacy: URL, _ destination: URL) throws -> Void) throws {
        try inTemporaryDirectory { dir in
            let legacy = dir.appendingPathComponent("Library/Application Support/Zonas/layout.json")
            let destination = dir.appendingPathComponent(".config/zonas/zonas.json5")
            try write(contents, to: legacy)

            try body(legacy, destination)
        }
    }

    @Test("The zones come across")
    func theZonesSurvive() throws {
        try migrating { legacy, destination in
            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination))

            let layout = try #require(LayoutFile.read(destination))
            #expect(layout.name == "Tres columnas")
            #expect(layout.zones.map(\.name) == ["Izquierda", "Centro"])
            #expect(layout.zones[1].width == 0.75)
        }
    }

    /// **The old file is the backup**, and it is a better one than a `.bak`
    /// beside it: it is the original, in the place muscle memory already knows,
    /// and nothing in the migration path can corrupt it because nothing in the
    /// migration path writes to it.
    @Test("The old file is not touched")
    func theOldFileIsLeftAlone() throws {
        try migrating { legacy, destination in
            let before = try Data(contentsOf: legacy)

            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let after = try Data(contentsOf: legacy)
            #expect(after == before)
        }
    }

    @Test("The new file says which version of the format it is")
    func versionIsAdded() throws {
        try migrating { legacy, destination in
            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let text = try String(contentsOf: destination, encoding: .utf8)
            #expect(text.contains("version: 1"))
        }
    }

    /// It appears out of nowhere in a directory the user may never have opened.
    @Test("The new file explains where it came from")
    func theNewFileExplainsItself() throws {
        try migrating { legacy, destination in
            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let text = try String(contentsOf: destination, encoding: .utf8)
            #expect(text.contains("moved here from"))
            #expect(text.contains("no longer read"))
        }
    }

    /// The whole reason migrations run over the tree rather than through the
    /// structs: a hand-edited v0 file keeps everything the structs never knew
    /// about.
    @Test("Comments and unknown keys in the old file survive the move")
    func handEditsSurvive() throws {
        let edited = """
        // my zones, do not laugh
        {
          "name": "Mine",
          "hotkey": "cmd-alt-z",
          "zones": [
            { "name": "All", "x": 0, "y": 0, "width": 1, "height": 1 }, // the only one
          ],
        }
        """

        try migrating(edited) { legacy, destination in
            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let text = try String(contentsOf: destination, encoding: .utf8)
            #expect(text.contains("// my zones, do not laugh"))
            #expect(text.contains("// the only one"))
            #expect(text.contains("hotkey"))
        }
    }

    @Test("A file that is already there is never overwritten")
    func anExistingFileWins() throws {
        try migrating { legacy, destination in
            try write("// mine, thanks\n{ name: \"Keep\", zones: [] }", to: destination)

            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination) == false)
            let kept = try String(contentsOf: destination, encoding: .utf8)
            #expect(kept.contains("mine, thanks"))
        }
    }

    @Test("Running twice does nothing the second time")
    func migratingIsIdempotent() throws {
        try migrating { legacy, destination in
            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination))
            let after = try Data(contentsOf: destination)

            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination) == false)
            let again = try Data(contentsOf: destination)
            #expect(again == after)
        }
    }

    @Test("Nothing to migrate is not a problem")
    func nothingToDo() throws {
        try inTemporaryDirectory { dir in
            let legacy = dir.appendingPathComponent("nothing/layout.json")
            let destination = dir.appendingPathComponent(".config/zonas/zonas.json5")

            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination) == false)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// A pre-1.0 file that cannot be read is not a reason to refuse to start.
    @Test("An unreadable old file leaves no new file and no crash")
    func abrokenOldFile() throws {
        try migrating("{ this is not json at all") { legacy, destination in
            #expect(LayoutMigration.migrateIfNeeded(from: legacy, to: destination) == false)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(FileManager.default.fileExists(atPath: legacy.path))
        }
    }
}

@Suite("Reading a file from a version that does not exist yet")
struct LayoutVersionTests {

    private func check(_ source: String) throws -> LayoutSchemaError? {
        #expect(throws: LayoutSchemaError.self) {
            try Layout.checkVersion(try LayoutSyntax.parse(source))
        }
    }

    @Test("The version this app writes is fine")
    func currentVersionIsFine() throws {
        #expect(throws: Never.self) {
            try Layout.checkVersion(try LayoutSyntax.parse("{ version: 1, name: \"x\" }"))
        }
    }

    /// A v0 file has no version key at all, and still reads.
    @Test("No version key at all is fine")
    func noVersionIsFine() throws {
        #expect(throws: Never.self) {
            try Layout.checkVersion(try LayoutSyntax.parse("{ name: \"x\" }"))
        }
    }

    /// Without this, a newer file meets an older reader and produces whatever
    /// pile of schema errors its new keys happen to cause — which reads as
    /// "your file is broken" when the truth is "this copy of Zonas is old".
    @Test("A newer file says to update Zonas, not that the file is wrong")
    func aNewerFileSaysSo() throws {
        let problem = try check("{\n  version: 2,\n  name: \"x\"\n}")

        #expect(problem?.line == 2)
        #expect(problem?.message.contains("update Zonas") == true)
    }

    @Test("A version that is not a number says so")
    func anonsenseVersion() throws {
        let problem = try check("{ version: \"one\" }")
        #expect(problem?.message == "version has to be a whole number")
    }
}

@Suite("Keys that v0 wrote and v1 does not have")
struct LegacyKeyTests {

    /// §3a removed `id` from the schema because the app was filling the file
    /// with UUIDs nobody had typed. Preserving unknown keys is the right rule
    /// for keys from the future; carrying `id` across would mean the first thing
    /// a migrating user sees in their new file is four UUIDs they did not write.
    ///
    /// Found by migrating a real file and reading the result, not by thinking
    /// about it.
    @Test("The UUIDs the old app wrote do not come across")
    func idsAreDropped() throws {
        try inTemporaryDirectory { dir in
            let legacy = dir.appendingPathComponent("old/layout.json")
            let destination = dir.appendingPathComponent("new/zonas.json5")
            try write("""
            {
              "name": "Tres columnas",
              "zones": [
                { "name": "Izquierda", "id": "B6D50A32-8418-467E-9BB2-A9724216EE7F",
                  "x": 0, "y": 0, "width": 0.25, "height": 1 }
              ]
            }
            """, to: legacy)

            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let text = try String(contentsOf: destination, encoding: .utf8)
            #expect(!text.contains("id:"))
            #expect(!text.contains("B6D50A32"))
            #expect(text.contains("Izquierda"))
        }
    }

    /// And a key that really is unknown still survives, or the migration would
    /// be eating things it has no business eating.
    @Test("A key from the future still comes across")
    func unknownKeysStillSurvive() throws {
        try inTemporaryDirectory { dir in
            let legacy = dir.appendingPathComponent("old/layout.json")
            let destination = dir.appendingPathComponent("new/zonas.json5")
            try write("""
            { "name": "L", "zones": [
                { "name": "A", "id": "x", "opacity": 0.5,
                  "x": 0, "y": 0, "width": 1, "height": 1 }
            ] }
            """, to: legacy)

            LayoutMigration.migrateIfNeeded(from: legacy, to: destination)

            let text = try String(contentsOf: destination, encoding: .utf8)
            #expect(text.contains("opacity"))
            #expect(!text.contains("id:"))
        }
    }
}
