import AppKit
import Testing
@testable import Zonas

/// Which screen the ⌘Tab switcher opens on — the half of it that has no system
/// calls in it, which is the half that can be wrong quietly.
///
/// The other half cannot be tested here at all: it needs two monitors, the
/// Accessibility permission and a live Dock, and it is written up in `Switcher`
/// and `DockDisplay` with the measurements that stand in for these.
@Suite("The switcher's screen")
struct SwitcherTests {

    /// A domain of its own, so a test run never writes into the real one and a
    /// developer's own pinned screen is not spent by `swift test`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "uy.com.fcstudio.zonas.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// The two screens every number in this file was measured on, in CG
    /// coordinates: a 5120-point ultrawide at the origin, and a notched MacBook
    /// to the left of it. `minY` is the **top** of a screen — `Coords` explains
    /// why everything internal is in this system — so the bottom edges are
    /// y = 1439 and y = 1345.
    private let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
    private let laptop = CGRect(x: -1728, y: 229, width: 1728, height: 1117)

    // MARK: - The pin

    @Test("A machine that has never been asked has no opinion")
    func unpinnedByDefault() {
        withDefaults { defaults in
            #expect(Switcher.pinned(defaults) == nil)
        }
    }

    @Test("Pinning a screen and reading it back")
    func pinRoundTrip() {
        withDefaults { defaults in
            Switcher.pin("00A4065B-8321-470E-A5E8-E0C215FF9481", defaults)
            #expect(Switcher.pinned(defaults) == "00A4065B-8321-470E-A5E8-E0C215FF9481")
        }
    }

    @Test("Unpinning leaves nothing behind, rather than an empty string")
    func unpinningClearsIt() {
        withDefaults { defaults in
            Switcher.pin("00A4065B-8321-470E-A5E8-E0C215FF9481", defaults)
            Switcher.pin(nil, defaults)
            #expect(Switcher.pinned(defaults) == nil)
        }
    }

    // MARK: - When a correction is owed

    @Test("Somewhere else than where it was pinned is the case this exists for")
    func driftIsACorrection() {
        #expect(Switcher.shouldCorrect(pinned: "A", current: "B"))
    }

    @Test("Already where it belongs costs a comparison and nothing else")
    func alreadyThere() {
        #expect(!Switcher.shouldCorrect(pinned: "A", current: "A"))
    }

    /// No pin is not "put it on the main screen". It is the behaviour macOS
    /// ships, which is what somebody who has never opened this menu has — and
    /// getting it wrong is not a no-op: it would walk the pointer to the bottom
    /// of a screen, once per ⌘, for somebody who never asked for anything.
    ///
    /// The argument here is deliberately *not* `current: nil`. That is the other
    /// test, and writing it that way is how this one passed while checking
    /// nothing.
    @Test("No pin is no opinion, not a default")
    func unpinnedNeverCorrects() {
        #expect(!Switcher.shouldCorrect(pinned: nil, current: "A"))
        #expect(!Switcher.shouldCorrect(pinned: nil, current: "B"))
    }

    /// Moving it drags the user's pointer to the bottom of a screen, and that
    /// cannot be taken back. Firing it on a guess about where the Dock is would
    /// be worse than leaving the switcher where it is.
    @Test("A Dock whose screen cannot be read is left alone")
    func unreadableNeverCorrects() {
        #expect(!Switcher.shouldCorrect(pinned: "A", current: nil))
        #expect(!Switcher.shouldCorrect(pinned: nil, current: nil))
    }

    // MARK: - The gesture

    /// The whole point of the path: it is a walk, not a teleport. A warp
    /// straight to the edge moves nothing — measured — so a path of one point
    /// would be a feature that silently does nothing.
    ///
    /// `steps + 1`, because the first point is the standing start that `push`
    /// warps to rather than posts. Asserting the travel as well as the count is
    /// the part that matters: the count alone was 5 when the path began one step
    /// in and carried 32 points instead of 40, and nothing said so.
    @Test("The path is a walk of the full run, not a jump")
    func severalSteps() {
        let path = Switcher.approach(intoBottomOf: ultrawide)
        let steps = Int((Switcher.approachDistance / Switcher.approachStep).rounded(.up))
        #expect(path.count == steps + 1)
        #expect(path.count == 6)

        // What the Dock is actually handed: the distance from the standing start
        // to the edge, which has to be the full `approachDistance`.
        #expect(path.last!.y - path.first!.y == Switcher.approachDistance)

        // And every posted event carries one whole step, none of them zero.
        let deltas = zip(path, path.dropFirst()).map { $1.y - $0.y }
        #expect(deltas == Array(repeating: Switcher.approachStep, count: steps))
    }

    /// `maxY` is the first row of the screen *below*, or of nothing at all.
    @Test("The walk goes down the middle and ends on the last row")
    func bottomEdge() {
        for frame in [ultrawide, laptop] {
            let path = Switcher.approach(intoBottomOf: frame)
            #expect(path.allSatisfy { $0.x == frame.midX })
            #expect(path.last?.y == frame.maxY - 1)
            #expect(path.first?.y == frame.maxY - 1 - Switcher.approachDistance)
        }
    }

    @Test("Every point of the path is on the screen it is aimed at")
    func staysOnTheScreen() {
        for frame in [ultrawide, laptop] {
            #expect(Switcher.approach(intoBottomOf: frame).allSatisfy { frame.contains($0) })
        }
    }

    /// Monotonic and downwards, because the Dock is watching for pressure: a
    /// path that wandered would be a hand that did not mean it.
    @Test("The path only ever moves towards the edge")
    func movesOneWay() {
        let path = Switcher.approach(intoBottomOf: ultrawide)
        #expect(zip(path, path.dropFirst()).allSatisfy { $0.y < $1.y })
    }

    /// Not a real screen, but the arithmetic has to survive one rather than
    /// hand back a path that starts above the top of it.
    @Test("A screen shorter than the run offers no path at all")
    func tooShortToWalk() {
        #expect(Switcher.approach(intoBottomOf: CGRect(x: 0, y: 0, width: 800, height: 30)).isEmpty)
    }

    /// macOS does not write `orientation` until somebody moves the Dock, so the
    /// absent case is the normal one — on most Macs it is the only one. A
    /// fallback of anything but `bottom` makes the feature refuse everywhere
    /// while looking entirely reasonable in the source, which is why this asks
    /// `reading` rather than trusting the enum's raw values.
    @Test("An unset Dock orientation is the bottom")
    func defaultEdge() {
        #expect(Switcher.Edge.reading(nil) == .bottom)
        #expect(Switcher.Edge.reading("bottom") == .bottom)
        #expect(Switcher.Edge.reading("left") == .left)
        #expect(Switcher.Edge.reading("right") == .right)
        // macOS does not offer a Dock at the top; anything unrecognised is the
        // same situation as the key being absent.
        #expect(Switcher.Edge.reading("top") == .bottom)
        #expect(Switcher.Edge.reading("") == .bottom)
    }
}
