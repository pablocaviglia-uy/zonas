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

    /// What gets written on the very first launch.
    ///
    /// The strongest documentation this project will ever ship is the first
    /// thing somebody sees when they open this file, and until now that was
    /// alphabetised `JSONEncoder` output where `height` came before `name`, with
    /// three UUIDs in it. A config file with no comments is not a config file,
    /// it is a dump.
    ///
    /// It has to parse into `Layout.threeColumns` exactly — the store starts
    /// from the built-in layout and reads this file on the next launch, so if
    /// the two ever disagreed the app would quietly change behaviour on a
    /// restart. There is a test that holds them together.
    static let seed = """
    // ~/Library/Application Support/Zonas/layout.json
    //
    // Zonas reads this file and never writes over it. Your comments, your
    // ordering and your names stay exactly as you left them. Edit, save, and
    // pick "Reload Zones" from the menu bar.
    //
    // Zones are fractions of the screen's usable area — what is left after the
    // menu bar, the Dock and, on the machines that have one, the notch. Keeping
    // them relative is what makes a layout written on the laptop land correctly
    // on the 34" monitor without redrawing it.
    //
    //        x: 0                                   x: 1
    //   y: 0 ┌───────────┬───────────────────────────┐
    //        │           │                           │
    //        │           │   { x: 0.25, y: 0,        │
    //        │           │     width: 0.75,          │
    //        │           │     height: 1 }           │
    //   y: 1 └───────────┴───────────────────────────┘
    //
    // If the file does not parse, Zonas says so in ~/Library/Logs/Zonas.log,
    // keeps the zones it already had, and does not touch a byte of what you
    // wrote.

    {
      name: "Three Columns",

      // Editor in the middle, docs on the left, chat on the right. It is the
      // layout that pays off the most on a wide monitor.
      //
      // Zones are allowed to overlap, and that is on purpose: when they do, the
      // SMALLEST one under the cursor wins, so a small zone can float on top of
      // a big one without the big one swallowing every drop.
      zones: [
        { name: "Left",   x: 0,    y: 0, width: 0.25, height: 1 },
        { name: "Center", x: 0.25, y: 0, width: 0.5,  height: 1 },
        { name: "Right",  x: 0.75, y: 0, width: 0.25, height: 1 },
      ],
    }

    """

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
            let decoder = JSONDecoder()
            // Comments, unquoted keys, trailing commas and `.25`, for one line
            // and no dependency — `allowsJSON5` is Foundation's. That is most of
            // why the format is JSON5 and not TOML: TOMLKit would mean C++
            // interop inside an executable that has to be signed and notarized.
            //
            // JSON5 is a superset of JSON, so every file written before this
            // still reads.
            decoder.allowsJSON5 = true
            return try decoder.decode(Layout.self, from: Data(contentsOf: url))
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
