import Foundation
import Testing
@testable import Zonas

@Suite("Deciding where the config file is")
struct LayoutLocationTests {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test("With no XDG_CONFIG_HOME it is ~/.config/zonas/zonas.json5")
    func theDefault() {
        let location = LayoutLocation(environment: [:], home: home)

        #expect(location.preferred.path == "/Users/someone/.config/zonas/zonas.json5")
        #expect(location.candidates.count == 1)
    }

    @Test("XDG_CONFIG_HOME is honoured")
    func xdgIsHonoured() {
        let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": "/Users/someone/cfg"],
                                      home: home)

        #expect(location.preferred.path == "/Users/someone/cfg/zonas/zonas.json5")
    }

    /// The spec says to ignore a relative value, and honouring one silently
    /// would be a way to write a file somewhere surprising.
    @Test("A relative or empty XDG_CONFIG_HOME is ignored")
    func nonsenseXDGIsIgnored() {
        for value in ["", "../..", "cfg", " "] {
            let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": value], home: home)

            #expect(location.preferred.path == "/Users/someone/.config/zonas/zonas.json5",
                    "XDG_CONFIG_HOME=\(value) was taken seriously")
        }
    }

    /// Setting XDG_CONFIG_HOME after having created ~/.config/zonas is the case
    /// this exists for: two files, and one of them about to be ignored.
    @Test("Setting XDG_CONFIG_HOME elsewhere means two places to look")
    func twoCandidates() {
        let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": "/Users/someone/cfg"],
                                      home: home)

        #expect(location.candidates.map(\.path) == [
            "/Users/someone/cfg/zonas/zonas.json5",
            "/Users/someone/.config/zonas/zonas.json5",
        ])
    }

    @Test("XDG_CONFIG_HOME pointing at ~/.config is not two places")
    func xdgPointingAtTheDefault() {
        let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": "/Users/someone/.config"],
                                      home: home)

        #expect(location.candidates.count == 1)
    }

    @Test("The pre-1.0 file is where it always was")
    func legacyPath() {
        let location = LayoutLocation(environment: [:], home: home)

        #expect(location.legacy.path
                == "/Users/someone/Library/Application Support/Zonas/layout.json")
    }
}

@Suite("Refusing to guess between two config files")
struct LayoutAmbiguityTests {

    @Test("With nothing on disk, it resolves to where a new one would go")
    func nothingYet() throws {
        try inTemporaryDirectory { dir in
            let location = LayoutLocation(environment: [:], home: dir)

            let resolved = try location.resolve()
            #expect(resolved == location.preferred)
        }
    }

    @Test("With one file, that is the one")
    func exactlyOne() throws {
        try inTemporaryDirectory { dir in
            let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": dir.path + "/cfg"],
                                          home: dir)
            try write("{}", to: location.candidates[0])

            let resolved = try location.resolve()
            #expect(resolved == location.candidates[0])
        }
    }

    /// Reading the first would mean silently ignoring a file the user wrote —
    /// and editing the ignored one looks exactly like the app being broken: you
    /// save, nothing happens, and nothing on screen explains it.
    @Test("With two files it refuses, and names both")
    func twoFiles() throws {
        try inTemporaryDirectory { dir in
            let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": dir.path + "/cfg"],
                                          home: dir)
            try write("{}", to: location.candidates[0])
            try write("{}", to: location.candidates[1])

            let problem = #expect(throws: LayoutLocation.Ambiguous.self) {
                try location.resolve()
            }

            #expect(problem?.paths.count == 2)
            #expect(problem?.description.contains(location.candidates[0].path) == true)
            #expect(problem?.description.contains(location.candidates[1].path) == true)
        }
    }

    /// Ambiguity is not a crash. The app runs on the built-in layout and the log
    /// carries both paths.
    @Test("An ambiguous location leaves the app on the built-in layout")
    func ambiguityIsSurvivable() throws {
        try inTemporaryDirectory { dir in
            let location = LayoutLocation(environment: ["XDG_CONFIG_HOME": dir.path + "/cfg"],
                                          home: dir)
            try write("{}", to: location.candidates[0])
            try write("{}", to: location.candidates[1])

            let store = LayoutStore(url: LayoutFile.defaultURL(location))

            #expect(store.fileURL == nil)
            #expect(store.layout == .threeColumns)
            #expect(store.reload() == .failed)
        }
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
