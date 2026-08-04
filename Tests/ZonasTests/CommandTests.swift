import Foundation
import Testing
@testable import Zonas

/// The exit code is a command-line tool's real contract: it is what a shell
/// script and a CI job read. The words on stdout are for people.
@Suite("The command line")
struct CommandTests {

    private let good = #"{ name: "Fine", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }"#

    private func inAFile(_ contents: String, _ body: (String) throws -> Void) throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try write(contents, to: url)
            try body(url.path)
        }
    }

    @Test("check on a layout that reads exits zero")
    func checkPasses() throws {
        try inAFile(good) { path in
            #expect(Command.run(["check", path]) == 0)
        }
    }

    @Test("check on a layout that does not read exits one")
    func checkFails() throws {
        try inAFile(#"{ name: "Bad", zones: [ { name: "A", x: 0, y: 0, width: "half", height: 1 } ] }"#) { path in
            #expect(Command.run(["check", path]) == 1)
        }
    }

    /// This is meant to live in the CI of somebody's dotfiles repo, where a zone
    /// hanging off the edge of a screen is worth saying out loud and is nobody's
    /// build failure.
    @Test("A warning is not a failure")
    func warningsDoNotFail() throws {
        try inAFile(#"{ name: "Over", zones: [ { name: "A", x: 0.5, y: 0, width: 0.75, height: 1 } ] }"#) { path in
            #expect(Command.run(["check", path]) == 0)
        }
    }

    @Test("The warnings say which zone and by how much")
    func whatTheWarningsSay() throws {
        let layout = try Layout(LayoutSyntax.parse(
            #"{ name: "Over", zones: [ { name: "Too wide", x: 0.5, y: 0, width: 0.75, height: 1 } ] }"#))

        let warnings = Command.warnings(about: layout)

        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Too wide"))
        #expect(warnings[0].contains("1.25"))
    }

    @Test("A layout with no zones is worth mentioning")
    func noZonesIsAWarning() throws {
        let layout = try Layout(LayoutSyntax.parse(#"{ name: "Empty", zones: [] }"#))

        #expect(Command.warnings(about: layout).contains { $0.contains("nothing will ever snap") })
    }

    /// gofmt's contract: `--check` reports and changes nothing.
    @Test("fmt --check reports without writing")
    func formatCheckDoesNotWrite() throws {
        let messy = #"{ name: "Messy", zones: [ { name: "A", x: 0, y: 0, width: 1, height: 1 } ] }"#
        try inAFile(messy) { path in
            #expect(Command.run(["fmt", path, "--check"]) == 1)
            let unchanged = try String(contentsOfFile: path, encoding: .utf8)
            #expect(unchanged == messy)
        }
    }

    @Test("fmt rewrites, and then has nothing left to do")
    func formatIsIdempotent() throws {
        try inAFile(#"{ name: "Messy", zones: [ { name: "A", x: 0, y: 0, width: 1, height: 1 } ] }"#) { path in
            #expect(Command.run(["fmt", path]) == 0)
            #expect(Command.run(["fmt", path, "--check"]) == 0)
            #expect(Command.run(["fmt", path]) == 0)
        }
    }

    /// Reformatting somebody's file is exactly where losing a comment would
    /// hurt most, so `fmt` runs the merge condition before it writes.
    @Test("fmt keeps every comment")
    func formatKeepsComments() throws {
        try inAFile("""
        // the header

        { name: "Commented",
          zones: [
            { name: "A", x: 0, y: 0, width: 1, height: 1 }, // the only one
          ] }

        // and a note at the end
        """) { path in
            #expect(Command.run(["fmt", path]) == 0)

            let after = try String(contentsOfFile: path, encoding: .utf8)
            #expect(after.contains("// the header"))
            #expect(after.contains("// the only one"))
            #expect(after.contains("// and a note at the end"))
        }
    }

    @Test("A command that does not exist exits two, not one")
    func unknownCommand() {
        #expect(Command.run(["frobnicate"]) == 2)
    }

    @Test("help and version work without a config file existing")
    func helpAndVersion() {
        #expect(Command.run(["help"]) == 0)
        #expect(Command.run(["version"]) == 0)
    }

    @Test("check on a file that is not there exits one")
    func missingFile() throws {
        try inTemporaryDirectory { dir in
            #expect(Command.run(["check", dir.appendingPathComponent("nope.json5").path]) == 1)
        }
    }
}
