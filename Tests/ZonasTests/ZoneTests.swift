import Foundation
import Testing
@testable import Zonas

@Suite("Reading a layout")
struct ZoneDecodingTests {

    /// `id` left the schema, and files written before that did not.
    ///
    /// Nothing had to be written for this to keep working — JSONDecoder ignores
    /// keys it does not know — which is precisely why it deserves a test: the
    /// compatibility is accidental, so nothing would tell you the day it broke.
    @Test("A file written when zones still carried ids still reads")
    func decodesFilesWrittenWithIDs() throws {
        let json = """
        {
          "name" : "Three Columns",
          "zones" : [
            {
              "height" : 1,
              "id" : "B6D50A32-8418-467E-9BB2-A9724216EE7F",
              "name" : "Left",
              "width" : 0.25,
              "x" : 0,
              "y" : 0
            }
          ]
        }
        """

        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))

        #expect(layout.name == "Three Columns")
        #expect(layout.zones == [Zone(name: "Left", x: 0, y: 0, width: 0.25, height: 1)])
    }

    /// The other half of the same story: what goes out no longer carries one.
    @Test("Saving does not put an id back into the file")
    func doesNotWriteIDs() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let text = String(decoding: try encoder.encode(Layout.threeColumns), as: UTF8.self)

        #expect(!text.contains("\"id\""))
    }

    /// The property the file watcher will lean on to ignore a save that only
    /// moved the whitespace around. It was false while `id` was in the schema:
    /// a fresh UUID per read made every read different from the last.
    @Test("Two reads of the same bytes compare equal")
    func readingIsStable() throws {
        let json = Data("""
        { "name": "Three Columns",
          "zones": [ { "name": "Left", "x": 0, "y": 0, "width": 0.25, "height": 1 } ] }
        """.utf8)

        let first = try JSONDecoder().decode(Layout.self, from: json)
        let second = try JSONDecoder().decode(Layout.self, from: json)

        #expect(first == second)
    }
}
