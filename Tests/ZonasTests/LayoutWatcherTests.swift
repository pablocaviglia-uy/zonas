import Foundation
import Testing
@testable import Zonas

/// Counts what the watcher reports, from whichever thread it reports on.
private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock(); count += 1; lock.unlock()
    }

    var seen: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Waits for the count to get past `mark`, pumping the run loop because the
    /// watcher reports on the main queue and a test that only slept would never
    /// let it get there.
    ///
    /// It takes a mark rather than just waiting for "any change" because
    /// **deleting the file is itself a change**. A test that waits for the count
    /// to become non-zero after a delete-then-recreate is satisfied by the
    /// delete and never checks that the recreate arrived at all — which is
    /// exactly how the first version of these tests passed against a watcher
    /// with its directory sources ripped out.
    func waitForMore(than mark: Int, within seconds: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while seen <= mark, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return seen > mark
    }

    func waitForOne(within seconds: TimeInterval = 3) -> Bool {
        waitForMore(than: 0, within: seconds)
    }

    /// Lets whatever is in flight arrive, then reports where the count stands.
    func settle() -> Int {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return seen
    }
}

/// One test per way a config file actually gets written, which is the point:
/// each of the four defeats a different naive implementation, and the fourth
/// leaves a watcher permanently deaf if the directory is not being watched too.
@Suite("Noticing that the file changed", .serialized)
struct LayoutWatcherTests {

    private func watching(_ body: (URL, Changes) throws -> Void) throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try Data("v0".utf8).write(to: url)

            let changes = Changes()
            let watcher = LayoutWatcher(url: url) { changes.record() }
            watcher.start()
            defer { watcher.stop() }

            // Let the sources arm before anything is written to.
            Thread.sleep(forTimeInterval: 0.2)
            try body(url, changes)
        }
    }

    @Test("A write in place")
    func writeInPlace() throws {
        try watching { url, changes in
            let handle = try #require(FileHandle(forWritingAtPath: url.path))
            handle.seekToEndOfFile()
            handle.write(Data("\n// v1".utf8))
            try handle.close()

            #expect(changes.waitForOne())
        }
    }

    /// `vim :w`, and this app's own `LayoutFile.write`. The descriptor being
    /// watched now refers to a file with no name.
    @Test("An atomic replace")
    func atomicReplace() throws {
        try watching { url, changes in
            try Data("v2".utf8).write(to: url, options: .atomic)

            #expect(changes.waitForOne())
        }
    }

    /// `git checkout` in a dotfiles repo, or a dotfiles manager relinking.
    @Test("A move over the top of it")
    func movedOver() throws {
        try watching { url, changes in
            let staged = url.deletingLastPathComponent().appendingPathComponent("staged")
            try Data("v3".utf8).write(to: staged)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)

            #expect(changes.waitForOne())
        }
    }

    /// The file comes back **before** the retries are spent, which the retry
    /// loop handles on its own — measured: this one still passes with the
    /// directory sources removed.
    ///
    /// Checking that the recreate itself was reported is not enough, because a
    /// quick delete-and-recreate collapses into a single notification anyway.
    /// The claim worth testing is that the watcher is still alive afterwards.
    @Test("The file comes back quickly, and it is still listening")
    func recreatedQuickly() throws {
        try watching { url, changes in
            try FileManager.default.removeItem(at: url)
            Thread.sleep(forTimeInterval: 0.1)
            try Data("v4".utf8).write(to: url)
            let afterRecreate = changes.settle()

            try Data("v5".utf8).write(to: url, options: .atomic)

            #expect(changes.waitForMore(than: afterRecreate),
                    "the watcher went deaf after the recreate")
        }
    }

    /// **The one that matters, and it took two tries to write.**
    ///
    /// The file gone for *longer* than the retry budget: checking out a branch
    /// that does not have it, moving the dotfiles repo, deleting it and coming
    /// back after a coffee. The retries are spent, the file source is dead, and
    /// only something watching the directory can bring it back.
    ///
    /// The first version of this test passed against a watcher with its
    /// directory sources ripped out — not because the retry loop covered it,
    /// but because **deleting the file is itself a change**, so waiting for "any
    /// change" was satisfied before the recreate ever happened. That is what
    /// `waitForMore(than:)` is for. Verified after fixing it: remove
    /// `armDirectories()` and this fails while the quick one above still passes.
    @Test("The file comes back after a long absence")
    func recreatedAfterALongAbsence() throws {
        try watching { url, changes in
            try FileManager.default.removeItem(at: url)
            // Comfortably past the retry budget, and past the delete's own
            // notification, which is the thing that made the first version of
            // this test pass for the wrong reason.
            let afterDelete = changes.settle()
            Thread.sleep(forTimeInterval: 1.0)

            try Data("back again".utf8).write(to: url)

            #expect(changes.waitForMore(than: afterDelete),
                    "the watcher gave up and never came back")
        }
    }

    /// The config symlinked out of a dotfiles repo — the arrangement this whole
    /// feature exists for. The write lands on the real file, and the watcher is
    /// following a link.
    @Test("A write through a symlink")
    func throughASymlink() throws {
        try inTemporaryDirectory { dir in
            let repo = dir.appendingPathComponent("dotfiles", isDirectory: true)
            let config = dir.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

            let real = repo.appendingPathComponent("zonas.json5")
            let link = config.appendingPathComponent("zonas.json5")
            try Data("v0".utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            let changes = Changes()
            let watcher = LayoutWatcher(url: link) { changes.record() }
            watcher.start()
            defer { watcher.stop() }
            Thread.sleep(forTimeInterval: 0.2)

            try LayoutFile.write(Data("v1".utf8), to: link)

            #expect(changes.waitForOne())
        }
    }

    /// One save produces two or three filesystem events. Without the settle
    /// time, one save would mean two or three reads of the file.
    @Test("A burst of writes is reported once")
    func burstsAreCollapsed() throws {
        try watching { url, changes in
            for version in 1...5 {
                try Data("v\(version)".utf8).write(to: url, options: .atomic)
            }

            #expect(changes.waitForOne())
            Thread.sleep(forTimeInterval: 0.4)
            #expect(changes.seen <= 2, "five writes produced \(changes.seen) reads")
        }
    }

    @Test("Nothing is reported once it has been stopped")
    func stoppingIsFinal() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try Data("v0".utf8).write(to: url)

            let changes = Changes()
            let watcher = LayoutWatcher(url: url) { changes.record() }
            watcher.start()
            Thread.sleep(forTimeInterval: 0.2)
            watcher.stop()

            try Data("v1".utf8).write(to: url, options: .atomic)
            Thread.sleep(forTimeInterval: 0.4)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))

            #expect(changes.seen == 0)
        }
    }
}
