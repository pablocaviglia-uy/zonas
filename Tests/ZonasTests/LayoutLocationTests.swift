import Foundation
import Testing
@testable import Zonas

@Suite("Deciding where the config file is")
struct LayoutLocationTests {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test("There is one path, and it is ~/.config/zonas/zonas.json5")
    func theOnePath() {
        let location = LayoutLocation(home: home)

        #expect(location.url.path == "/Users/someone/.config/zonas/zonas.json5")
    }

    @Test("The pre-1.0 file is where it always was")
    func legacyPath() {
        let location = LayoutLocation(home: home)

        #expect(location.legacy.path
                == "/Users/someone/Library/Application Support/Zonas/layout.json")
    }

    /// `$XDG_CONFIG_HOME` was honoured for about an hour, and then removed after
    /// running it. A GUI app on macOS is launched by Finder or by launchd and
    /// never sees a shell's exports, so the app would read `~/.config` while
    /// `zonas check` in a terminal read somewhere else — silently, with only one
    /// of the two files existing, so no amount of checking for duplicates could
    /// catch it.
    ///
    /// The supported way to keep the file elsewhere is a symlink, which is
    /// resolved by the filesystem rather than by an environment the app and the
    /// terminal do not share.
    @Test("The environment cannot move it, because the app cannot read the environment")
    func theEnvironmentIsIgnored() {
        let plain = LayoutLocation(home: home)

        setenv("XDG_CONFIG_HOME", "/Users/someone/somewhere-else", 1)
        defer { unsetenv("XDG_CONFIG_HOME") }

        #expect(LayoutLocation(home: home).url == plain.url)
    }

    /// And a symlink is: the file handling resolves them, the writer keeps them
    /// intact, and the watcher follows them. That is what makes it a real answer
    /// rather than a consolation.
    @Test("A symlinked config is read through the link")
    func aSymlinkedConfigIsRead() throws {
        try inTemporaryDirectory { dir in
            let repo = dir.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let real = repo.appendingPathComponent("zonas.json5")
            try write(#"{ name: "From the repo", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }"#,
                      to: real)

            let location = LayoutLocation(home: dir)
            try FileManager.default.createDirectory(at: location.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: location.url, withDestinationURL: real)

            let store = LayoutStore(url: location.url)

            #expect(store.layout.name == "From the repo")
        }
    }
}

@Suite("Telling the app what is wrong with the file")
struct LayoutProblemTests {

    @Test("A file that reads leaves no problem to report")
    func nothingToReport() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try write(#"{ name: "Fine", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }"#,
                      to: url)

            #expect(LayoutStore(url: url).problem == nil)
        }
    }

    /// The menu has to be able to name the line, so the store keeps the reason
    /// rather than dropping it into the log on the way past.
    @Test("A broken file leaves a problem that names the line")
    func aproblemIsKept() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try write(#"{ name: "Fine", zones: [ { name: "A", x: 0, y: 0, width: "half", height: 1 } ] }"#,
                      to: url)

            let store = LayoutStore(url: url)

            #expect(store.problem?.hasPrefix("line 1:") == true)
            #expect(store.layout == .threeColumns)
        }
    }

    @Test("Fixing the file clears it again")
    func fixingItClearsTheProblem() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("zonas.json5")
            try write("{ name: \"Fine\", zones: [ ,, ] }", to: url)
            let store = LayoutStore(url: url)
            #expect(store.problem != nil)

            try write(#"{ name: "Fixed", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }"#,
                      to: url)

            #expect(store.reload() == .changed)
            #expect(store.problem == nil)
        }
    }

    /// No file at all is a first launch, not a problem to shout about.
    @Test("A missing file is not an error")
    func amissingFileIsNotAProblem() throws {
        try inTemporaryDirectory { dir in
            let store = LayoutStore(url: dir.appendingPathComponent("nothing.json5"))

            #expect(store.problem == nil)
            #expect(store.layout == .threeColumns)
        }
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
