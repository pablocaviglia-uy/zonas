import Foundation
import Testing
@testable import Zonas

@Suite("Reading a layout")
struct ZoneDecodingTests {

    /// `id` left the schema, and files written before that did not.
    ///
    /// The reader ignores keys it does not know, so nothing had to be written
    /// for this to keep working — which is precisely why it deserves a test: the
    /// compatibility is free, so nothing would tell you the day it stopped.
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

        let layout = try Layout(LayoutSyntax.parse(json))

        #expect(layout.name == "Three Columns")
        #expect(layout.zones == [Zone(name: "Left", x: 0, y: 0, width: 0.25, height: 1)])
    }

    /// The other half of the same story: what gets written no longer carries one.
    @Test("The starting file has no id key in it")
    func doesNotWriteIDs() {
        #expect(!LayoutFile.seed.contains("id:"))
        #expect(!LayoutFile.seed.contains("\"id\""))
    }

    /// The property the file watcher will lean on to ignore a save that only
    /// moved the whitespace around. It was false while `id` was in the schema:
    /// a fresh UUID per read made every read different from the last.
    @Test("Two reads of the same bytes compare equal")
    func readingIsStable() throws {
        let json = """
        { "name": "Three Columns",
          "zones": [ { "name": "Left", "x": 0, "y": 0, "width": 0.25, "height": 1 } ] }
        """

        let first = try Layout(LayoutSyntax.parse(json))
        let second = try Layout(LayoutSyntax.parse(json))

        #expect(first == second)
    }
}
