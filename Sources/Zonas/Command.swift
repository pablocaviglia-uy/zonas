import AppKit

/// What the same binary does when you run it from a terminal.
///
/// One executable, two behaviours: with no arguments it is the menu bar app,
/// with arguments it answers and exits before AppKit is ever started. That is
/// not a trick, it is the cheapest way to have both — a second binary would
/// need its own signing, its own notarization and its own place in the disk
/// image, to run the same three hundred lines.
///
/// `zonas monitors` in particular is not a convenience. §6 of the plan makes
/// per-monitor layouts the bet the project rides on, and a rule matched by
/// monitor name is unwritable if the app never tells you what the names are.
/// AeroSpace ships `list-monitors` and FancyZones ships `get-monitors` for the
/// same reason. Config-first does not mean guess.
enum Command: String, CaseIterable {
    case check
    case fmt
    case monitors
    case apps
    case help
    case version

    /// Runs the command and returns a process exit code.
    static func run(_ arguments: [String]) -> Int32 {
        guard let first = arguments.first else { return help() }
        guard let command = Command(rawValue: first) else {
            print("zonas: there is no command called \"\(first)\"")
            return help(code: 2)
        }

        let rest = Array(arguments.dropFirst())
        // A path argument is not a convenience either. `zonas check` in the CI
        // of a dotfiles repo has to check the file *in the repo*, which is not
        // the one installed on the runner — and there is no installed one.
        let path = rest.first { !$0.hasPrefix("-") }
        let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        switch command {
        case .check: return check(url ?? LayoutLocation().url)
        case .fmt: return format(url ?? LayoutLocation().url, writing: !rest.contains("--check"))
        case .monitors: return listMonitors()
        case .apps: return listApps()
        case .help: return help()
        case .version: return printVersion()
        }
    }

    // MARK: - check

    /// Reads the file and says what is wrong with it, if anything.
    ///
    /// Errors exit non-zero and warnings do not: this belongs in the CI of
    /// somebody's dotfiles repo, where a zone hanging off the edge of a screen
    /// is worth mentioning and is nobody's build failure.
    private static func check(_ url: URL) -> Int32 {
        print("zonas: \(abbreviate(url))")

        do {
            let layout = try LayoutFile.load(url)
            print("OK — \"\(layout.name)\", \(layout.zones.count) zone"
                  + (layout.zones.count == 1 ? "" : "s")
                  + ", gap \(Int(layout.gap)), margin \(Int(layout.margin)), "
                  + "\(layout.modifier.symbol) \(layout.modifier.rawValue)"
                  + (layout.span.map { " + \($0.symbol) \($0.rawValue) to span" }
                     ?? ", no key to span with"))
            if !layout.ignored.isEmpty {
                print("ignoring \(layout.ignored.count) app"
                      + (layout.ignored.count == 1 ? "" : "s")
                      + ": " + layout.ignored.sorted().joined(separator: ", "))
            }

            for warning in warnings(about: layout) { print("warning: \(warning)") }
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    /// Things that are legal, parse cleanly, and are almost certainly not what
    /// somebody meant.
    static func warnings(about layout: Layout) -> [String] {
        var found: [String] = []

        for zone in layout.zones {
            // A fraction outside 0…1 puts part of the window off the screen. It
            // is allowed — there is no reason to forbid it — but nobody has ever
            // typed it on purpose the first time.
            if zone.x < 0 || zone.y < 0 || zone.x + zone.width > 1.0001
                || zone.y + zone.height > 1.0001 {
                found.append("\"\(zone.name)\" reaches outside the screen "
                             + "(x + width = \(trim(zone.x + zone.width)), "
                             + "y + height = \(trim(zone.y + zone.height)))")
            }
        }
        if layout.zones.isEmpty {
            found.append("this layout has no zones, so nothing will ever snap")
        }
        return found
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.4g", value)
    }

    // MARK: - fmt

    /// Makes the file canonical, or says that it is not.
    ///
    /// The contract is `gofmt`'s and the reason is in §4: the format is
    /// canonical and a tool makes it so **when you ask**, so the one large
    /// reformat is a deliberate, reviewable act instead of a surprise diff on a
    /// morning you were doing something else.
    private static func format(_ url: URL, writing: Bool) -> Int32 {
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            let document = try LayoutSyntax.parse(original)
            let rendered = LayoutSyntax.render(document)

            guard rendered != original else {
                print("zonas: \(abbreviate(url)) is already canonical")
                return 0
            }
            guard writing else {
                print("zonas: \(abbreviate(url)) would be reformatted")
                return 1
            }

            // This is the first thing in the whole app that writes a layout, so
            // it is the first place the merge condition stops being theoretical.
            // Refusing to write beats writing something that quietly dropped a
            // line the user typed.
            let lost = try LayoutSyntax.commentsLost(rendering: document)
            guard lost.isEmpty else {
                print("zonas: REFUSING to write — formatting would lose \(lost.count) comment"
                      + (lost.count == 1 ? "" : "s") + ":")
                lost.forEach { print("    \($0)") }
                print("    this is a bug in Zonas, not in your file. Please report it.")
                return 1
            }

            try LayoutFile.write(Data(rendered.utf8), to: url)
            print("zonas: reformatted \(abbreviate(url))")
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - monitors

    /// What to write in a `screens` rule, for the screens plugged in right now.
    private static func listMonitors() -> Int32 {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            print("zonas: no screens, which should not be possible")
            return 1
        }

        for screen in screens {
            let id = screen.displayID ?? 0
            let frame = screen.frame
            let usable = screen.visibleFrame

            print("\(screen.localizedName)")
            print("    name:      \"\(screen.localizedName)\"")
            print("    size:      \(Int(frame.width))×\(Int(frame.height)) points"
                  + "   usable \(Int(usable.width))×\(Int(usable.height))")
            print("    builtin:   \(CGDisplayIsBuiltin(id) != 0)")
            print("    displayID: \(id)")
            print("")
        }
        return 0
    }

    // MARK: - apps

    /// What to write in the `ignore` list, for the applications running now.
    ///
    /// This is `monitors`' argument one level down, and it is the same argument:
    /// a rule matched on a bundle identifier is unwritable if the app never
    /// tells you what the identifiers are, and nobody knows theirs by heart. §6
    /// puts it as "config-first does not mean guess".
    ///
    /// It lists what is running rather than everything installed, because the
    /// question this answers is always asked about an application that is on
    /// screen and misbehaving.
    private static func listApps() -> Int32 {
        // Only the ones with a Dock icon and a menu bar. A `.accessory` process
        // has no window anybody can drag, so listing forty of them would bury
        // the six that can be answers.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        guard !running.isEmpty else {
            print("zonas: nothing with a window is running")
            return 1
        }

        let widest = running.map { ($0.localizedName ?? "").count }.max() ?? 0
        for app in running {
            let name = app.localizedName ?? "?"
            let padding = String(repeating: " ", count: max(0, widest - name.count))
            // A process with no bundle identifier cannot be put in the list at
            // all, and saying so here is much cheaper than letting somebody
            // discover it by writing a line that never matches.
            guard let identifier = app.bundleIdentifier else {
                print("\(name)\(padding)   (no bundle identifier — cannot be ignored)")
                continue
            }
            print("\(name)\(padding)   \"\(identifier)\"")
        }

        print("")
        print("Put the ones Zonas should leave alone in the ignore list:")
        print("")
        print("    ignore: [")
        print("      \"\(running.first?.bundleIdentifier ?? "com.apple.Safari")\",")
        print("    ],")
        return 0
    }

    // MARK: - the rest

    private static func printVersion() -> Int32 {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("zonas \(short) (build \(build))")
        return 0
    }

    @discardableResult
    private static func help(code: Int32 = 0) -> Int32 {
        print("""
        zonas — snap windows into zones you define in a file

        Running it with no arguments starts the menu bar app.

            check [file]        read the layout and say what is wrong with it
            fmt [file]          rewrite the layout file in canonical form
            fmt [file] --check  say whether it would be rewritten, change nothing
            monitors            what to write in a rule, for the screens you have
            apps                what to write in `ignore`, for the apps running now
            version
            help

        Without a file it uses ~/.config/zonas/zonas.json5. Give it one to check
        the copy in your dotfiles repo instead — which is what you want in CI,
        where nothing is installed.

        $XDG_CONFIG_HOME is deliberately not honoured: a GUI app on macOS never
        sees your shell's environment, so the app and this command would disagree
        about which file is your config. Symlink it instead — that works for
        both, and Zonas will not clobber the link.
        """)
        return code
    }

    private static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
