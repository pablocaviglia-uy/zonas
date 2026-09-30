import CoreGraphics
import Foundation
import Testing
@testable import Zonas

/// ⌥Tab — the half that decides which windows are on the list, in what order,
/// and where a press lands.
///
/// The other half reads the real windows and brings one forward, and it cannot
/// be reached from here: it needs the Accessibility permission and other
/// applications' windows. Its measurements are in `AXWindow.bringForward` and
/// `WindowSwitcherController.read`.
@Suite("Which windows ⌥Tab goes through, and in what order")
struct WindowSwitcherOrderTests {

    private let own: pid_t = 1
    private let chrome: pid_t = 100
    private let teams: pid_t = 200
    private let emulator: pid_t = 300
    private let finder: pid_t = 400

    /// The middle column of the ultrawide, which is where two windows snapped
    /// into the same zone both end up — to the point.
    private let centro = CGRect(x: 1280, y: 30, width: 2560, height: 1410)

    private func listed(_ id: CGWindowID, _ pid: pid_t,
                        layer: Int = 0, alpha: Double = 1, bounds: CGRect? = nil) -> WindowSwitcher.Listed {
        WindowSwitcher.Listed(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds ?? centro)
    }

    private func window(_ name: String, _ id: CGWindowID?, _ pid: pid_t,
                        subrole: String? = "AXStandardWindow", title: String? = nil,
                        minimized: Bool = false, hidden: Bool = false) -> WindowSwitcher.Window<String> {
        WindowSwitcher.Window(handle: name, id: id, pid: pid, subrole: subrole,
                              title: title ?? name, isMinimized: minimized, isHidden: hidden)
    }

    private func order(_ listed: [WindowSwitcher.Listed],
                       _ windows: [WindowSwitcher.Window<String>]) -> [String] {
        WindowSwitcher.entries(listed: listed, windows: windows, own: own).entries.map(\.window.handle)
    }

    /// The case this feature exists for. Chrome lists its own two windows in
    /// its own order, which says nothing about where Teams' window sits
    /// between them; only the WindowServer's list does.
    @Test("The order is the screen's, not each application's")
    func theScreensOrder() {
        let windows = [window("Chrome B", 12, chrome), window("Chrome A", 11, chrome),
                       window("Teams", 21, teams)]
        let screen = [listed(11, chrome), listed(21, teams), listed(12, chrome)]

        #expect(order(screen, windows) == ["Chrome A", "Teams", "Chrome B"])
    }

    /// Why the join is by window number. Two windows snapped into the same
    /// zone have the same frame, and are the pair most likely to be switched
    /// between; a join on the frame could not tell them apart.
    @Test("Two windows with the same frame keep the screen's order, both ways round")
    func sameFrameKeepsItsOrder() {
        let windows = [window("Chrome A", 11, chrome), window("Chrome B", 12, chrome)]

        #expect(order([listed(12, chrome), listed(11, chrome)], windows) == ["Chrome B", "Chrome A"])
        #expect(order([listed(11, chrome), listed(12, chrome)], windows) == ["Chrome A", "Chrome B"])
    }

    @Test("Zonas' own windows are not on the list, and not reported as left out")
    func notOurOwn() {
        let windows = [window("Editor", 1, own), window("Chrome", 11, chrome)]
        let result = WindowSwitcher.entries(listed: [listed(1, own), listed(11, chrome)],
                                            windows: windows, own: own)

        #expect(result.entries.map(\.window.handle) == ["Chrome"])
        #expect(result.leftOut.isEmpty)
    }

    /// Layer 0 is where applications' ordinary windows are. Above it are the
    /// menu bar, the Dock, menus and overlays; at alpha 0 is a window that is
    /// on screen only in the sense of not having been closed.
    @Test("Nothing above the ordinary layer, and nothing invisible")
    func ordinaryAndVisible() {
        let windows = [window("Floating", 11, chrome), window("Invisible", 12, chrome),
                       window("Plain", 13, chrome)]
        let screen = [listed(11, chrome, layer: 3), listed(12, chrome, alpha: 0), listed(13, chrome)]

        #expect(order(screen, windows) == ["Plain"])
    }

    /// Something no application admits to has no handle to raise it by.
    @Test("A window the WindowServer lists and no application describes is not a stop")
    func listedButUndescribed() {
        #expect(order([listed(99, chrome), listed(11, chrome)], [window("Chrome", 11, chrome)])
                == ["Chrome"])
    }

    @Test("Minimized windows and hidden applications come after everything on screen")
    func offScreenLast() {
        let windows = [window("Tucked away", 13, chrome, minimized: true),
                       window("Chrome", 11, chrome),
                       window("Teams, hidden", 21, teams, hidden: true),
                       window("Finder", 41, finder)]
        let screen = [listed(41, finder), listed(11, chrome)]
        let result = WindowSwitcher.entries(listed: screen, windows: windows, own: own).entries

        #expect(result.map(\.window.handle) == ["Finder", "Chrome", "Tucked away", "Teams, hidden"])
        #expect(result.map { $0.bounds == nil } == [false, false, true, true],
                "only what is on screen has somewhere to be")
    }

    /// Bringing it forward would slide the whole desktop sideways, which is a
    /// different gesture — and it is not a window being refused, so it is not
    /// reported as one either.
    @Test("A window that is neither on screen nor put away is on another Space, and not on the list")
    func anotherSpace() {
        let result = WindowSwitcher.entries(listed: [listed(11, chrome)],
                                            windows: [window("Chrome", 11, chrome),
                                                      window("Elsewhere", 12, chrome)],
                                            own: own)

        #expect(result.entries.map(\.window.handle) == ["Chrome"])
        #expect(result.leftOut.isEmpty)
    }

    /// The Android emulator's 54 × 506 floating toolbar, as it describes itself
    /// on the machine this was written on.
    @Test("The emulator's toolbar is left out, and reported as left out")
    func theToolbar() {
        let toolbar = window("Toolbar", 31, emulator, subrole: "AXDialog", title: "")
        let result = WindowSwitcher.entries(
            listed: [listed(31, emulator, bounds: CGRect(x: 2000, y: 400, width: 54, height: 506)),
                     listed(32, emulator)],
            windows: [toolbar, window("Android Emulator - Medium_Tablet:5554", 32, emulator)],
            own: own)

        #expect(result.entries.map(\.window.handle) == ["Android Emulator - Medium_Tablet:5554"])
        #expect(result.leftOut.map(\.handle) == ["Toolbar"])
    }

    /// Accessibility lists Finder's desktop as one of Finder's windows, with
    /// no subrole, no title and no number. The first run of this reported it
    /// on every press, and nobody has ever looked for it on a list.
    @Test("Only a window that is on screen is reported as left out")
    func onlyWhatCanBeSeen() {
        let desktop = window("Desktop", nil, finder, subrole: nil, title: "")
        let result = WindowSwitcher.entries(listed: [listed(41, finder)],
                                            windows: [desktop, window("Downloads", 41, finder)],
                                            own: own)

        #expect(result.entries.map(\.window.handle) == ["Downloads"])
        #expect(result.leftOut.isEmpty)
    }

    @Test("A standard window always counts; anything else needs a title")
    func whatCounts() {
        #expect(WindowSwitcher.isSwitchable(subrole: "AXStandardWindow", title: nil))
        #expect(WindowSwitcher.isSwitchable(subrole: "AXStandardWindow", title: ""))
        #expect(WindowSwitcher.isSwitchable(subrole: "AXDialog", title: "Settings"))
        #expect(WindowSwitcher.isSwitchable(subrole: "AXUnknown", title: "Steam"))
        #expect(!WindowSwitcher.isSwitchable(subrole: "AXDialog", title: ""))
        #expect(!WindowSwitcher.isSwitchable(subrole: "AXFloatingWindow", title: nil))
        // Finder's desktop answers with neither.
        #expect(!WindowSwitcher.isSwitchable(subrole: nil, title: nil))
    }

    @Test("The system's own panels are left out whatever they are called")
    func theSystemsOwn() {
        #expect(!WindowSwitcher.isSwitchable(subrole: "AXSystemDialog", title: "Notification Center"))
        #expect(!WindowSwitcher.isSwitchable(subrole: "AXSystemFloatingWindow", title: "Panel"))
    }
}

@Suite("Where a press of ⌥Tab lands")
struct WindowSwitcherCycleTests {

    /// The first entry is the window you are in, so one tap goes back to the
    /// one you were in before it.
    @Test("The first press chooses the second window")
    func firstPress() {
        #expect(WindowSwitcher.Cycle(count: 5, backwards: false)?.index == 1)
    }

    @Test("With one window, the first press chooses it")
    func oneWindow() {
        #expect(WindowSwitcher.Cycle(count: 1, backwards: false)?.index == 0)
        #expect(WindowSwitcher.Cycle(count: 1, backwards: true)?.index == 0)
    }

    @Test("With no windows there is nothing to choose")
    func noWindows() {
        #expect(WindowSwitcher.Cycle(count: 0, backwards: false) == nil)
    }

    @Test("Going backwards starts from the far end, the way ⌘⇧Tab does")
    func backwards() {
        #expect(WindowSwitcher.Cycle(count: 5, backwards: true)?.index == 4)
    }

    @Test("It wraps at both ends")
    func wraps() {
        var cycle = WindowSwitcher.Cycle(count: 3, backwards: false)!
        cycle.step(1)
        #expect(cycle.index == 2)
        cycle.step(1)
        #expect(cycle.index == 0)
        cycle.step(-1)
        #expect(cycle.index == 2)
    }

    /// What a click on a row does: one step of however far it is.
    @Test("A step of any size lands where it says")
    func anyStep() {
        var cycle = WindowSwitcher.Cycle(count: 7, backwards: false)!
        cycle.step(5 - cycle.index)
        #expect(cycle.index == 5)
        cycle.step(0 - cycle.index)
        #expect(cycle.index == 0)
    }
}

@Suite("Which rows of a long list are drawn")
struct WindowSwitcherScrollTests {

    @Test("A list that fits never scrolls")
    func fits() {
        #expect(WindowSwitcher.top(showing: 4, from: 0, count: 5, capacity: 10) == 0)
    }

    @Test("Moving within the visible rows moves nothing")
    func staysPut() {
        #expect(WindowSwitcher.top(showing: 7, from: 5, count: 30, capacity: 10) == 5)
    }

    @Test("Past the last row, it scrolls just far enough to show the choice at the bottom")
    func scrollsDown() {
        #expect(WindowSwitcher.top(showing: 15, from: 5, count: 30, capacity: 10) == 6)
    }

    @Test("Above the first row, the choice becomes the first row")
    func scrollsUp() {
        #expect(WindowSwitcher.top(showing: 3, from: 5, count: 30, capacity: 10) == 3)
    }

    /// ⌥Tab from the last window goes back to the first, and the list with it.
    @Test("Wrapping round goes back to the top")
    func wrapsToTheTop() {
        #expect(WindowSwitcher.top(showing: 0, from: 20, count: 30, capacity: 10) == 0)
    }

    @Test("A starting row past the end is pulled back to a full page")
    func neverPastTheEnd() {
        #expect(WindowSwitcher.top(showing: 29, from: 28, count: 30, capacity: 10) == 20)
    }
}

@Suite("What the list says about each window")
struct WindowSwitcherLabelTests {

    /// The layout on the machine this was written on, as in `ShortcutTests`.
    private let layout = Layout(name: "Tres columnas", zones: [
        Zone(name: "Izquierda Arriba", x: 0,    y: 0,        width: 0.25, height: 0.5),
        Zone(name: "Izquierda Abajo",  x: 0,    y: 0.5,      width: 0.25, height: 0.5),
        Zone(name: "Centro",           x: 0.25, y: 0,        width: 0.5,  height: 1),
        Zone(name: "Derecha 3",        x: 0.75, y: 0,        width: 0.25, height: 0.476526),
        Zone(name: "Derecha 4",        x: 0.75, y: 0.476526, width: 0.25, height: 0.523474),
    ])
    private let ultrawide = CGRect(x: 0, y: 30, width: 5120, height: 1410)
    private let laptop = CGRect(x: 0, y: 33, width: 1728, height: 1084)

    private func snapped(_ index: Int, on area: CGRect) -> CGRect {
        layout.frame(of: layout.zones[index], in: area)
    }

    @Test("A browser's signature comes off the end of the title")
    func signaturesComeOff() {
        #expect(WindowSwitcher.title("Opciones Mixamo - Google Chrome", application: "Google Chrome")
                == "Opciones Mixamo")
        #expect(WindowSwitcher.title("Chat | Daily Stand Up | Microsoft Teams", application: "Microsoft Teams")
                == "Chat | Daily Stand Up")
        #expect(WindowSwitcher.title("Notes — TextEdit", application: "TextEdit") == "Notes")
    }

    @Test("A title that is only the application's name, or has no signature, is left alone")
    func otherTitlesStay() {
        #expect(WindowSwitcher.title("Claude", application: "Claude") == "Claude")
        #expect(WindowSwitcher.title("Containers – 5 running", application: "OrbStack")
                == "Containers – 5 running")
        #expect(WindowSwitcher.title("Why Google Chrome", application: "Google Chrome")
                == "Why Google Chrome")
    }

    @Test("A window with no title is called by its application")
    func noTitle() {
        #expect(WindowSwitcher.title(nil, application: "Finder") == "Finder")
        #expect(WindowSwitcher.title("  ", application: "Finder") == "Finder")
    }

    @Test("A window snapped into a zone is in it")
    func snappedIsIn() {
        for index in layout.zones.indices {
            #expect(WindowSwitcher.place(of: snapped(index, on: ultrawide), in: layout, area: ultrawide)
                    == .zones([index]))
        }
    }

    /// The floors `AXWindow.setFrame` measured, against the laptop's
    /// 428-point right-hand column: nudged back onto the screen, flush right.
    @Test("An application too wide for its zone is still in it")
    func tooWideIsStillIn() {
        let zone = snapped(4, on: laptop)
        let chrome = CGRect(x: laptop.maxX - 500, y: zone.minY, width: 500, height: zone.height)
        let whatsapp = CGRect(x: laptop.maxX - 800, y: zone.minY, width: 800, height: zone.height)

        #expect(WindowSwitcher.place(of: chrome, in: layout, area: laptop) == .zones([4]))
        #expect(WindowSwitcher.place(of: whatsapp, in: layout, area: laptop) == .zones([4]))
    }

    @Test("A window spread across the left column with the span key is in both zones")
    func spanned() {
        let column = layout.frame(of: Zone(name: "", x: 0, y: 0, width: 0.25, height: 1), in: ultrawide)
        #expect(WindowSwitcher.place(of: column, in: layout, area: ultrawide) == .zones([0, 1]))
    }

    /// The reason this is not `zoneIndex(holding:)`: Finder's "Downloads",
    /// sitting over the middle column, is not in it.
    @Test("A floating window over a zone is floating")
    func floating() {
        let finder = CGRect(x: 2000, y: 400, width: 1049, height: 587)
        #expect(WindowSwitcher.place(of: finder, in: layout, area: ultrawide) == .floating)
    }

    @Test("A maximised window is on the whole screen, not in the middle zone")
    func wholeScreen() {
        let maximised = layout.frame(of: Layout.maximised, in: ultrawide)
        #expect(WindowSwitcher.place(of: maximised, in: layout, area: ultrawide) == .wholeScreen)
    }

    /// A file may put a small zone on top of a big one. A window in either is
    /// in that one, not in both.
    @Test("A zone on top of a bigger one is told apart from it")
    func overlappingZones() {
        let stacked = Layout(name: "Stacked", zones: [
            Zone(name: "Big", x: 0, y: 0, width: 0.75, height: 1),
            Zone(name: "Small", x: 0.1, y: 0.25, width: 0.3, height: 0.5),
        ])
        let big = stacked.frame(of: stacked.zones[0], in: ultrawide)
        let small = stacked.frame(of: stacked.zones[1], in: ultrawide)

        #expect(WindowSwitcher.place(of: big, in: stacked, area: ultrawide) == .zones([0]))
        #expect(WindowSwitcher.place(of: small, in: stacked, area: ultrawide) == .zones([1]))
    }

    @Test("Cells shrink to fit, then stop shrinking and the strip scrolls")
    func strip() {
        #expect(WindowSwitcher.strip(count: 10, room: 1000) == .init(cell: 84, visible: 10))
        #expect(WindowSwitcher.strip(count: 20, room: 1260) == .init(cell: 63, visible: 20))
        #expect(WindowSwitcher.strip(count: 40, room: 1260) == .init(cell: 56, visible: 22))
        #expect(WindowSwitcher.strip(count: 0, room: 1260).visible == 0)
    }

    @Test("A preview keeps the window's shape and is never enlarged")
    func fit() {
        let box = CGSize(width: 560, height: 350)
        #expect(WindowSwitcher.fit(CGSize(width: 2552, height: 1410), into: box) == CGSize(width: 560, height: 309))
        #expect(WindowSwitcher.fit(CGSize(width: 1276, height: 1410), into: box) == CGSize(width: 317, height: 350))
        #expect(WindowSwitcher.fit(CGSize(width: 300, height: 200), into: box) == CGSize(width: 300, height: 200))
        #expect(WindowSwitcher.fit(.zero, into: box) == .zero)
    }

    /// The ring is the other caller, and it wants the opposite: the picture
    /// goes on the window's own rectangle out on the desktop, which is several
    /// times the size the strip showed it at.
    @Test("For the ring the same picture is blown up to the window's own size")
    func fitEnlarged() {
        let window = CGSize(width: 1276, height: 668)
        let picture = CGSize(width: 480, height: 251)

        #expect(WindowSwitcher.fit(picture, into: window, enlarging: true) == CGSize(width: 1276, height: 667))
        #expect(WindowSwitcher.fit(picture, into: window) == picture)

        // A picture taken a press ago, of a window that has been resized since:
        // it keeps its own shape and is letterboxed, rather than being stretched
        // into a rectangle that was never its own.
        #expect(WindowSwitcher.fit(CGSize(width: 480, height: 480), into: window, enlarging: true)
                == CGSize(width: 668, height: 668))
        #expect(WindowSwitcher.fit(.zero, into: window, enlarging: true) == .zero)
    }
}

@Suite("What stays chosen when ⌥Q closes a window")
struct WindowSwitcherCloseTests {

    private func cycle(_ count: Int, at index: Int) -> WindowSwitcher.Cycle {
        var cycle = WindowSwitcher.Cycle(count: count, backwards: false)!
        cycle.step(index - cycle.index)
        return cycle
    }

    @Test("Closing the chosen window chooses the one that took its place")
    func theChosenOne() {
        let after = cycle(5, at: 2).removing(2)
        #expect(after?.count == 4)
        #expect(after?.index == 2)
    }

    @Test("Closing the chosen window at the end chooses the one before it")
    func theLastOne() {
        #expect(cycle(5, at: 4).removing(4)?.index == 3)
    }

    @Test("Closing another window keeps the same window chosen")
    func anotherOne() {
        #expect(cycle(5, at: 3).removing(1)?.index == 2, "the chosen window moved up one place")
        #expect(cycle(5, at: 1).removing(3)?.index == 1)
    }

    @Test("Closing the only window leaves nothing to choose")
    func theOnlyOne() {
        #expect(cycle(1, at: 0).removing(0) == nil)
    }

    @Test("A position that is not on the list changes nothing")
    func nothingThere() {
        #expect(cycle(3, at: 1).removing(7) == cycle(3, at: 1))
    }
}

@Suite("The two switches for ⌥Tab's pictures")
struct WindowPreviewSettingsTests {

    /// A domain of its own, so a test run never writes into the real one and
    /// the developer's own preference is not spent by `swift test`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "uy.com.fcstudio.zonas.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// The one that would go wrong silently: `bool(forKey:)` answers `false`
    /// for a key nobody has written, which would turn both of these off for
    /// everybody who has never opened the menu.
    @Test("Never having said anything is not the same as having said no")
    func onByDefault() {
        withDefaults { defaults in
            #expect(WindowPreviews.isOn(defaults))
            #expect(WindowPreviews.isInRing(defaults))
        }
    }

    @Test("Turning them off, and back on")
    func switching() {
        withDefaults { defaults in
            WindowPreviews.setOn(false, defaults)
            #expect(!WindowPreviews.isOn(defaults))
            // The ring's own switch is untouched by the master: turning
            // previews off and on again gives back the menu you left.
            #expect(WindowPreviews.isInRing(defaults))

            WindowPreviews.setInRing(false, defaults)
            WindowPreviews.setOn(true, defaults)
            #expect(WindowPreviews.isOn(defaults))
            #expect(!WindowPreviews.isInRing(defaults))
        }
    }

    /// They are two keys and not one enumeration, so that a version that
    /// learns a third place to put a picture does not have to migrate anybody's
    /// preference.
    @Test("The two switches are independent")
    func independent() {
        withDefaults { defaults in
            WindowPreviews.setInRing(false, defaults)
            #expect(WindowPreviews.isOn(defaults))
            #expect(!WindowPreviews.isInRing(defaults))
        }
    }
}
