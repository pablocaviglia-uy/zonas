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
/// ### Why `$XDG_CONFIG_HOME` is deliberately not honoured
///
/// This was written honouring it, and then reverted after running it, which is
/// the only reason the problem was found: **a GUI app on macOS cannot see your
/// shell's environment.** It is launched by Finder or by launchd, neither of
/// which has ever sourced your `.zshrc`. So for anybody who sets the variable to
/// something other than `~/.config`:
///
/// - the app, which cannot see it, reads `~/.config/zonas/zonas.json5`
/// - `zonas check` in a terminal, which can, reads somewhere else entirely
///
/// They disagree about which file is your config, silently, and no amount of
/// checking for two files catches it because only one of them exists. "You save
/// and nothing happens" is precisely the failure this project keeps eliminating,
/// and honouring the variable would build one in on purpose.
///
/// The supported way to keep the file elsewhere is a **symlink**, which works
/// identically for the app and for the command line because it is resolved by
/// the filesystem rather than by an environment neither of them shares. That is
/// not a consolation prize: writing through a symlink without destroying it, and
/// watching both the link and its target, are already done and tested.
struct LayoutLocation {

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// The layout file. There is one path and it is this one.
    var url: URL {
        home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zonas", isDirectory: true)
            .appendingPathComponent("zonas.json5")
    }

    /// The pre-1.0 location, which is read once and then left alone forever.
    var legacy: URL {
        home
            .appendingPathComponent("Library/Application Support/Zonas", isDirectory: true)
            .appendingPathComponent("layout.json")
    }
}
