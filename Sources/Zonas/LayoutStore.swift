import Foundation

/// The layout the app is currently working with.
///
/// It holds exactly one thing —the layout in memory— and knows which file it
/// came from. It used to hold four: the path, the reading and writing, the
/// state, and the hit-testing. Those went to `LayoutFile` (path and I/O) and to
/// `Layout` itself (hit-testing, which never needed a file to answer).
///
/// The split is not tidiness. With the path baked into the initializer there was
/// no way to point the store at a temporary directory, so the cases that most
/// need a test — a broken file, a file that disappears, two writers — were
/// exactly the ones only testable by hand, one at a time, against your own
/// config.
final class LayoutStore {

    /// The instance the app uses. Everything else takes a URL.
    static let shared = LayoutStore(url: LayoutFile.defaultURL())

    private let url: URL
    private(set) var layout: Layout

    /// What is wrong with the file right now, in the user's words, or `nil`.
    ///
    /// The store keeps it so that the menu can say which line to go and look at.
    /// While the log was the only audience an error had, swallowing it there was
    /// enough; a menu bar item that says "the file is broken" and nothing else
    /// is only marginally better than silence.
    private(set) var problem: String?

    init(url: URL) {
        self.url = url
        // At startup there is no last good layout to keep, so the built-in one
        // is the only answer. That is not the same decision as `reload()`'s.
        do {
            layout = try LayoutFile.load(url)
        } catch is LayoutFile.Missing {
            layout = .threeColumns
        } catch {
            layout = .threeColumns
            problem = "\(error)"
            Log.write("layout: FAILED to read \(url.path) — \(error)")
        }
    }

    /// Path of the file, so it can be opened from the menu.
    var fileURL: URL { url }

    /// Writes the starting file, only if there is no file yet.
    ///
    /// This is what gets called at startup. It used to be a bare `save()`, and
    /// that clobbered the user's file every time parsing failed: a typo took
    /// all of their zones with it. With launch at login that would happen on
    /// the next login, when nobody is watching any more.
    ///
    /// What it writes is `LayoutFile.seed` — the file as a human would write
    /// it — and not the encoded layout. The error is only logged because there
    /// is no window to put it in yet; the first-launch window is Stage 2.
    func createIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try LayoutFile.write(Data(LayoutFile.seed.utf8), to: url)
            Log.write("layout: wrote the starting file at \(url.path)")
        } catch {
            Log.write("layout: FAILED to create \(url.path) — \(error)")
        }
    }

    // There is deliberately no `save()`.
    //
    // The one that was here encoded the `Codable` structs, which is a writer
    // that cannot help destroying every comment in the file the first time
    // anything calls it — and nothing did. A layout writer arrives with
    // `LayoutSyntax`, which renders from a tree that remembers the comments and
    // the keys this version does not know about. Until then, the honest amount
    // of code for writing a layout is none.

    /// Re-reads the file. If it cannot be read, **what is in memory stays**.
    ///
    /// It used to fall back to the built-in layout, which meant one comma too
    /// many replaced the zones you were using with three columns you never
    /// asked for. That punishes a typo by throwing away the last thing that
    /// worked, at the exact moment you are editing the file and least want a
    /// surprise. The built-in layout is what you get when there is nothing at
    /// all — it is not a recovery mode.
    ///
    /// The last good layout being the fallback is also what lets the editor
    /// have an `invalid` state later: something coherent is still on screen
    /// while the file is broken.
    @discardableResult
    func reload() -> Reload {
        do {
            let fresh = try LayoutFile.load(url)
            // Recovering is a state transition and belongs in the log. Without
            // it, reading the log later shows a FAILED with no resolution after
            // it, which reads as still broken.
            if problem != nil { Log.write("layout: reads fine again") }
            problem = nil
            guard fresh != layout else { return .unchanged }
            layout = fresh
            return .changed
        } catch {
            problem = "\(error)"
            Log.write("layout: FAILED to read \(url.path) — \(error)")
            Log.write("layout: the file is NOT touched")
            return .failed
        }
    }

    /// What a reload turned out to be.
    ///
    /// `unchanged` is not pedantry. A file watcher fires for a save that only
    /// moved whitespace, for a save that changed a comment, and for a `touch` —
    /// and a log that says "reloaded" every time is a log nobody reads. This is
    /// what `Layout` being `Equatable` was for.
    enum Reload {
        case changed
        case unchanged
        case failed
    }
}
