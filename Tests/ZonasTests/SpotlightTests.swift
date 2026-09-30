import AppKit
import Foundation
import Testing
@testable import Zonas

/// What ⌥Tab draws around the chosen window, on a screen the test can state the
/// size of rather than ask the machine for.
@Suite("Dimming the rest of the screen around the chosen window")
struct SpotlightTests {

    /// The built-in screen, as a view covering it sees itself.
    private let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    /// The ultrawide, which is the screen the guides exist for.
    private let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "uy.com.fcstudio.zonas.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: - The switch

    /// The same reason `WindowPreviews` gives: `bool(forKey:)` answers `false`
    /// for a key nobody has written, which would turn this off for everybody
    /// who has never opened the menu.
    @Test("Nobody having opened the menu is not the same as having said no")
    func onByDefault() {
        withDefaults { defaults in
            #expect(Spotlight.isOn(defaults))
            Spotlight.setOn(false, defaults)
            #expect(!Spotlight.isOn(defaults))
            Spotlight.setOn(true, defaults)
            #expect(Spotlight.isOn(defaults))
        }
    }

    // MARK: - The guides

    @Test("A window in the middle gets a line through each of its four edges")
    func fourGuides() {
        let hole = CGRect(x: 1280, y: 300, width: 2560, height: 800)
        let lines = Spotlight.guides(around: hole, in: ultrawide)

        #expect(lines.count == 4)
        // The two verticals run the whole height, the two horizontals the whole
        // width: a guide that stopped short would be a tick, and a tick can only
        // be found by already looking where the window is.
        let verticals = lines.filter { $0.height == ultrawide.height }
        let horizontals = lines.filter { $0.width == ultrawide.width }
        #expect(verticals.count == 2)
        #expect(horizontals.count == 2)
    }

    @Test("Each line is centred on the edge it belongs to")
    func centredOnTheEdge() {
        let hole = CGRect(x: 400, y: 200, width: 600, height: 300)
        let lines = Spotlight.guides(around: hole, in: laptop, thickness: 4)

        let verticals = lines.filter { $0.height == laptop.height }.map(\.midX).sorted()
        let horizontals = lines.filter { $0.width == laptop.width }.map(\.midY).sorted()
        #expect(verticals == [400, 1000])
        #expect(horizontals == [200, 500])
        #expect(lines.allSatisfy { $0.width == 4 || $0.height == 4 })
    }

    /// A window can straddle two monitors. On the screen holding its right-hand
    /// half the left edge is not somewhere a line belongs: it would come out
    /// pinned to the bezel, pointing at an edge that is on the other monitor.
    @Test("A window straddling two screens gets no line for the edge that is elsewhere")
    func aStraddlingWindowDropsTheFarEdge() {
        let straddling = CGRect(x: -700, y: 300, width: 1400, height: 400)
        let lines = Spotlight.guides(around: straddling, in: laptop)

        #expect(lines.count == 3, "the left edge is on the other monitor")
        let verticals = lines.filter { $0.height == laptop.height }
        #expect(verticals.count == 1)
        #expect(verticals.first?.midX == 700)
    }

    @Test("A window on another screen entirely gets nothing drawn for it here")
    func anotherScreenGetsScrimOnly() {
        let elsewhere = CGRect(x: 2000, y: 200, width: 600, height: 400)
        #expect(!Spotlight.holds(elsewhere, in: laptop))
        #expect(Spotlight.guides(around: elsewhere, in: laptop).isEmpty)
    }

    @Test("A window on this screen is held by it")
    func thisScreenHoldsIt() {
        #expect(Spotlight.holds(CGRect(x: 10, y: 10, width: 100, height: 100), in: laptop))
        // Straddling still counts: the half that is here is drawn here.
        #expect(Spotlight.holds(CGRect(x: -700, y: 300, width: 1400, height: 400), in: laptop))
    }

    /// The window flush against the top-left of the usable area — its edges lie
    /// exactly on the screen's, which is the case an exclusive comparison would
    /// silently drop.
    @Test("An edge exactly on the screen's own edge still gets its line")
    func anEdgeOnTheBoundaryCounts() {
        let flush = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(Spotlight.guides(around: flush, in: laptop).count == 4)
    }

    // MARK: - How dark

    /// The editor's scrim is 0.6 and this is deliberately lighter: ⌥Tab is a
    /// choice *between* the other windows, so a scrim that made them one dark
    /// rectangle would take away the thing being chosen from.
    @Test("It is lighter than the editor's scrim, and still a scrim")
    func dimmerThanTheEditor() {
        #expect(Spotlight.dim > 0.2 && Spotlight.dim < 0.6)
        #expect(Spotlight.guideAlpha < 1, "the guides are for the corner of the eye")
    }
}
