import Foundation

/// The layout file on disk.
///
/// Every write in the app goes through here, and it exists as its own thing for
/// one reason: writing this file correctly is not obvious, and the mistake is
/// invisible when you make it.
enum LayoutFile {

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
