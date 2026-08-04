import Foundation

/// Where the layout file lives.
///
/// It moved, in 1.0, from `~/Library/Application Support/Zonas/layout.json` to
/// `~/.config/zonas/zonas.json5`. Two separate reasons, and both matter:
///
/// **The extension was a lie.** A file full of comments and unquoted keys that
/// calls itself `.json` misinforms every tool that opens it — the editor picks
/// the wrong syntax highlighting, `jq` refuses it, a linter in CI flags a
/// perfectly good file. `.json5` is what it is.
///
/// **`~/Library/Application Support` is not somewhere you keep dotfiles.** The
/// whole point of this file is that it goes in a git repo and gets symlinked
/// onto every machine you own, and nobody's dotfiles repo has an
/// `Application Support` directory in it. `~/.config` is where the tools this
/// competes with already look.
///
/// Everything here takes its environment as a parameter rather than reading the
/// process's, so a test can describe a machine instead of running on one.
struct LayoutLocation {

    private let configHome: URL?
    private let home: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // An XDG_CONFIG_HOME that is empty or relative is not a config home.
        // The spec says to ignore it, and silently honouring `../..` would be a
        // way to write a file somewhere surprising.
        if let raw = environment["XDG_CONFIG_HOME"], raw.hasPrefix("/") {
            configHome = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            configHome = nil
        }
        self.home = home
    }

    /// Where a new file gets created.
    var preferred: URL {
        directory(under: configHome ?? home.appendingPathComponent(".config", isDirectory: true))
    }

    /// The pre-1.0 location, which is read once and then left alone forever.
    var legacy: URL {
        home
            .appendingPathComponent("Library/Application Support/Zonas", isDirectory: true)
            .appendingPathComponent("layout.json")
    }

    /// Every place a config could legitimately be, most specific first.
    ///
    /// There are two only when `XDG_CONFIG_HOME` is set to something that is not
    /// `~/.config`, which is exactly the case that needs care: somebody who set
    /// that variable *after* creating `~/.config/zonas/` has two files and one
    /// of them is about to be ignored.
    var candidates: [URL] {
        var directories = [configHome ?? home.appendingPathComponent(".config", isDirectory: true)]
        let dotConfig = home.appendingPathComponent(".config", isDirectory: true)
        if directories[0].standardizedFileURL != dotConfig.standardizedFileURL {
            directories.append(dotConfig)
        }
        return directories.map(directory(under:))
    }

    private func directory(under base: URL) -> URL {
        base
            .appendingPathComponent("zonas", isDirectory: true)
            .appendingPathComponent("zonas.json5")
    }

    /// The file to read, or a refusal to guess.
    ///
    /// When two candidates both exist there is no defensible way to pick one.
    /// Reading the first would mean silently ignoring a file the user wrote, and
    /// editing the ignored one would look exactly like the app being broken —
    /// you save, nothing happens, and there is nothing on screen to explain it.
    /// So it says so, names both paths, and reads neither.
    ///
    /// - Returns: the existing file, or `preferred` when there is none yet.
    func resolve(using fileManager: FileManager = .default) throws -> URL {
        let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }

        guard existing.count <= 1 else {
            throw Ambiguous(paths: existing)
        }
        return existing.first ?? preferred
    }

    /// Two config files, and no way to choose.
    struct Ambiguous: Error, CustomStringConvertible {
        let paths: [URL]

        var description: String {
            "there is more than one config file and no way to tell which you meant:\n"
                + paths.map { "         \($0.path)" }.joined(separator: "\n")
                + "\n         delete or rename one of them"
        }
    }
}
