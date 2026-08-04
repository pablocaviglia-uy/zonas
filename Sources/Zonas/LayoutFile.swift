import Foundation

/// The layout file on disk.
///
/// Every write in the app goes through here, and it exists as its own thing for
/// one reason: writing this file correctly is not obvious, and the mistake is
/// invisible when you make it.
enum LayoutFile {

    /// Where the file lives when nobody says otherwise.
    ///
    /// It is a `static` and not a property of the store on purpose: everything
    /// that reads or writes the layout takes a URL, so a test can point the
    /// whole thing at a directory of its own. While this was baked into the
    /// store's initializer there was no way to exercise the file handling at all
    /// without touching the real config of whoever ran the tests.
    ///
    /// This one line is also the entire surface the XDG work has to replace.
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Zonas/layout.json")
    }()

    /// Reads the layout. `nil` means there is nothing usable here.
    ///
    /// What the caller does about it is the caller's business — at startup it
    /// means the built-in layout, on a reload it means keeping what was already
    /// working — but the **reason** is always in the log. The `try?`s that used
    /// to be here swallowed it, and one comma too many looked exactly like
    /// having no file at all.
    static func read(_ url: URL) -> Layout? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
        } catch {
            Log.write("layout: FAILED to read \(url.path) — \(error)")
            Log.write("layout: the file is NOT touched")
            return nil
        }
    }

    /// Writes the file atomically, **without destroying a symlink**.
    ///
    /// Two things have to be true at once and only one of them is intuitive.
    ///
    /// Atomic, because a half-written file is a parse error the moment a file
    /// watcher exists, and a crash mid-write would take the layouts with it.
    ///
    /// And symlink-preserving, because `.atomic` on its own writes to a
    /// temporary file and renames it over the target — which **replaces the
    /// symlink with a regular file**. Somebody whose config is symlinked out of
    /// a dotfiles repo would get a stale repo copy and a broken link, silently:
    /// no error anywhere, and the app keeps working against the file it just
    /// orphaned. Measured, with the three candidate implementations:
    ///
    /// ```
    /// [A plain ] still a symlink: true  | real file: PLAIN
    /// [B atomic] still a symlink: false | real file: ORIGINAL   <-- repo stale
    /// [C resolv] still a symlink: true  | real file: ATOMIC-RESOLVED
    /// ```
    ///
    /// `resolvingSymlinksInPath()` is what makes it case C: the rename happens
    /// over the real file, in the real file's directory — which also keeps the
    /// temporary file on the same volume, so the rename stays atomic.
    ///
    /// `URLResourceValues.canonicalPath` does **not** work here: verified, it
    /// resolves `/var`→`/private/var` but hands back the link's own path rather
    /// than the target's.
    ///
    /// The comment is this long on purpose. The bug does not exist today, it
    /// costs nothing to reintroduce, and nothing about a plain `.atomic` write
    /// looks wrong while you are typing it.
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}
