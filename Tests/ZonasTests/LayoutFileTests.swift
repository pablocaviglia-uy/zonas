import Foundation
import Testing
@testable import Zonas

@Suite("Writing the layout file")
struct LayoutFileTests {

    /// The whole point of this test.
    ///
    /// A plain `.atomic` write renames a temporary file over the target and
    /// leaves a regular file where the symlink was: the dotfiles repo keeps the
    /// old contents forever and nothing anywhere reports a problem. It is not a
    /// hypothesis, it was measured — and the day somebody simplifies the write
    /// path, this is the only thing that will notice.
    @Test("Writing through a symlink updates the real file and keeps the link")
    func writingThroughASymlinkKeepsIt() throws {
        try inTemporaryDirectory { dir in
            let repo = dir.appendingPathComponent("dotfiles", isDirectory: true)
            let config = dir.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

            let real = repo.appendingPathComponent("zonas.json")
            let link = config.appendingPathComponent("zonas.json")
            try Data("ORIGINAL".utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            try LayoutFile.write(Data("WRITTEN".utf8), to: link)

            // attributesOfItem does not follow the link, which is exactly what
            // has to be asked here.
            let type = try FileManager.default
                .attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
            #expect(type == .typeSymbolicLink,
                    "the write replaced the symlink with a regular file")
            #expect(try String(contentsOf: real, encoding: .utf8) == "WRITTEN",
                    "the write went somewhere else and left the real file stale")
        }
    }

    /// First launch: `~/.config/zonas/` does not exist yet.
    @Test("The folder is created when it is not there")
    func createsTheFolder() throws {
        try inTemporaryDirectory { dir in
            let url = dir
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("zonas", isDirectory: true)
                .appendingPathComponent("zonas.json")

            try LayoutFile.write(Data("HELLO".utf8), to: url)

            #expect(try String(contentsOf: url, encoding: .utf8) == "HELLO")
        }
    }

    /// A write that cannot happen has to say so. The version this replaced
    /// returned `false` into a `@discardableResult` and a read-only config
    /// folder was indistinguishable from success.
    @Test("A write that cannot happen throws instead of going quiet")
    func failureSurfaces() throws {
        try inTemporaryDirectory { dir in
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(
                at: locked,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o500])
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: locked.path)
            }

            #expect(throws: (any Error).self) {
                try LayoutFile.write(Data("NOPE".utf8),
                                     to: locked.appendingPathComponent("zonas.json"))
            }
        }
    }
}

/// Sends the log somewhere harmless, once, before any test can write to it.
///
/// A global `let` is initialized lazily and exactly once, and every test that
/// can reach `Log.write` gets there through `inTemporaryDirectory` — so by the
/// time anything logs, this has already run.
private let logGoesToAScratchFile: Void = {
    Log.url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("zonas-tests.log")
}()

/// Runs `body` against a directory of its own and takes it away afterwards.
func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    _ = logGoesToAScratchFile
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("zonas-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}
