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
final class ZoneStore {

    /// The instance the app uses. Everything else takes a URL.
    static let shared = ZoneStore(url: LayoutFile.defaultURL)

    private let url: URL
    private(set) var layout: Layout

    init(url: URL) {
        self.url = url
        // At startup there is no last good layout to keep, so the built-in one
        // is the only answer. That is not the same decision as `reload()`'s.
        layout = LayoutFile.read(url) ?? .threeColumns
    }

    /// Path of the file, so it can be opened from the menu.
    var fileURL: URL { url }

    /// Writes the built-in layout only if there is no file yet.
    ///
    /// This is what gets called at startup. It used to be a bare `save()`, and
    /// that clobbered the user's file every time parsing failed: a typo took
    /// all of their zones with it. With launch at login that would happen on
    /// the next login, when nobody is watching any more.
    func createIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try save()
        } catch {
            Log.write("layout: FAILED to create \(url.path) — \(error)")
        }
    }

    /// Writes the current layout, creating the folder if needed.
    ///
    /// It throws rather than returning a `Bool` because the only caller used to
    /// discard that `Bool`: a read-only config folder, a full disk or a wrong
    /// permission all ended the same way, with the app carrying on in silence.
    /// An error that reaches the log at least names itself.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LayoutFile.write(encoder.encode(layout), to: url)
    }

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
    func reload() -> Bool {
        guard let fresh = LayoutFile.read(url) else { return false }
        layout = fresh
        return true
    }
}
