import Foundation
import Testing
@testable import Zonas

@Suite("The file the first launch writes")
struct SeedTests {

    /// The one that matters.
    ///
    /// The store starts from `Layout.threeColumns` and reads the file on the
    /// next launch. If the two ever drifted apart, the app would work one way
    /// today and another way after a restart, with nothing to point at.
    @Test("It parses, and into exactly the built-in layout")
    func theSeedIsTheBuiltInLayout() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("layout.json")
            try LayoutFile.write(Data(LayoutFile.seed.utf8), to: url)

            #expect(LayoutFile.read(url) == .threeColumns)
        }
    }

    /// Which also proves the reader accepts what the file is written in:
    /// comments, unquoted keys and a trailing comma would all be syntax errors
    /// without `allowsJSON5`.
    @Test("It is written in the syntax the reader accepts")
    func theSeedUsesJSON5() {
        #expect(LayoutFile.seed.contains("//"), "no comments — then it is a dump")
        #expect(LayoutFile.seed.contains("name: "), "keys got quoted")
        #expect(LayoutFile.seed.contains("],"), "the trailing comma went away")
    }

    /// Plain JSON is JSON5, so nothing written before this stops reading.
    @Test("The reader still takes ordinary JSON")
    func plainJSONStillReads() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("layout.json")
            try Data(#"{"name":"Plain","zones":[{"name":"All","x":0,"y":0,"width":1,"height":1}]}"#.utf8)
                .write(to: url)

            #expect(LayoutFile.read(url)?.name == "Plain")
        }
    }

    @Test("A file that does not parse reads as nothing at all")
    func brokenFilesReadAsNil() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("layout.json")
            try Data("{ name: \"Broken\", zones: [ ,, ] }".utf8).write(to: url)

            #expect(LayoutFile.read(url) == nil)
        }
    }
}
