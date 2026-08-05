import AppKit
import Testing
@testable import Zonas

/// The first-launch window's decisions, which are the half of it that can be
/// wrong without anybody noticing.
@Suite("The welcome window")
struct WelcomeTests {

    /// A domain of its own, so a test run never writes into the real one and a
    /// developer's own "I have read this" is not spent by `swift test`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "uy.com.fcstudio.zonas.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: - When it opens

    @Test("It opens on a machine that has never seen it")
    func opensOnFirstLaunch() {
        withDefaults { defaults in
            #expect(Welcome.shouldOpen(defaults))
        }
    }

    @Test("Once the user has closed it, it does not open again")
    func staysClosedAfterwards() {
        withDefaults { defaults in
            Welcome.dismiss(defaults)
            #expect(!Welcome.shouldOpen(defaults))
        }
    }

    /// The reason the flag records the user's action rather than the app's.
    ///
    /// Anything that ends the process before the user has finished — a crash, a
    /// `pkill`, quitting from the menu to go and read the README — must leave
    /// first launch still owed, because this window is the only face the app
    /// has and a second launch without it is the grey icon and the silence it
    /// exists to prevent. Showing the window is not what spends the flag.
    @Test("Showing it is not what spends it — only closing it is")
    func openingTwiceWithoutClosingStillOwesTheWindow() {
        withDefaults { defaults in
            #expect(Welcome.shouldOpen(defaults))
            #expect(Welcome.shouldOpen(defaults), "asking twice must not consume it")
            Welcome.dismiss(defaults)
            #expect(!Welcome.shouldOpen(defaults))
        }
    }

    // MARK: - The three states

    @Test("Trusted and deaf is not the same state as denied")
    func theThreeStates() {
        #expect(Welcome.Readiness(trusted: false, tapIsLive: false) == .denied)
        // The one that matters: macOS says yes and the tap did not come up.
        // Until now this arrived at the icon as the same `setActive(false)` as
        // an outright denial, which sends the reader to turn on a switch that
        // is already on.
        #expect(Welcome.Readiness(trusted: true, tapIsLive: false) == .grantedButDeaf)
        #expect(Welcome.Readiness(trusted: true, tapIsLive: true) == .working)
        // A tap cannot be live without the permission, but the type allows it to
        // be asked and the answer must not be "working".
        #expect(Welcome.Readiness(trusted: false, tapIsLive: true) == .denied)
    }

    @Test("Each state says something different, and only one of them is done")
    func eachStateReadsDifferently() {
        let all: [Welcome.Readiness] = [.denied, .grantedButDeaf, .working]
        #expect(Set(all.map(\.headline)).count == 3)
        #expect(Set(all.map(\.detail)).count == 3)

        #expect(Welcome.Readiness.working.action == nil,
                "a button reopening the panel on a switch that is already right invites breaking it")
        #expect(Welcome.Readiness.denied.action != nil)
        #expect(Welcome.Readiness.grantedButDeaf.action != nil)

        #expect(Welcome.Readiness.working.isWorking)
        #expect(!Welcome.Readiness.denied.isWorking)
        #expect(!Welcome.Readiness.grantedButDeaf.isWorking)
    }

    /// PLAN §2, which is the most expensive thing this project knows and the
    /// only state in which it is any use to the reader: with an ad-hoc or
    /// changed signature the switch stays on while `AXIsProcessTrusted()`
    /// answers false forever, and **only removing the entry and adding it again
    /// rewrites the recorded requirement.** Two off/on cycles were measured
    /// against tccd's log and both stayed denied.
    @Test("The stuck state carries the fix that actually works")
    func theStuckStateSaysMinusAndPlus() {
        let detail = Welcome.Readiness.grantedButDeaf.detail
        #expect(detail.contains("−") && detail.contains("+"),
                "off and on again does not rewrite the code requirement; − and + do")
    }

    // MARK: - The gesture, in the keys the file names

    @Test("The gesture names the key from the file, not the one in the sentence")
    func theGestureFollowsTheFile() {
        var layout = Layout.threeColumns
        layout.modifier = .command
        layout.span = .option

        let gesture = Welcome.gesture(layout)
        #expect(gesture.contains("⌘"))
        #expect(!gesture.contains("⇧"), "Shift is the default, not the truth")

        let spanning = Welcome.spanning(layout)
        #expect(spanning?.contains("⌥") == true)
    }

    @Test("A layout with no span key gets no sentence about one")
    func noSpanKeyNoSentence() {
        var layout = Layout.threeColumns
        layout.span = nil
        #expect(Welcome.spanning(layout) == nil)
    }

    /// MacsyZones has an issue asking for the key order to be made irrelevant,
    /// filed by somebody who was never told there was an order. On macOS ⌃ held
    /// while the button goes down *is* the secondary click, so pressing it first
    /// turns the whole gesture into a right-click and nothing happens at all.
    @Test("It says which key comes first, because the order is the instruction")
    func theOrderIsStated() {
        var layout = Layout.threeColumns
        layout.span = .control
        #expect(Welcome.spanning(layout)?.contains("first") == true)
    }

    // MARK: - The sketch of the menu bar

    /// The real numbers off this machine: a 1728-point screen whose notch spans
    /// x ∈ [771, 956], with Zonas' icon at 1133…1169.5.
    @Test("The sketch is the screen's own proportions")
    func theSketchIsMeasured() {
        let sketch = Welcome.Sketch.of(
            bar: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            notch: CGRect(x: 771, y: 1085, width: 185, height: 32),
            icon: CGRect(x: 1133, y: 1084, width: 36.5, height: 33),
            iconIsVisible: true)

        #expect(sketch.hasNotch)
        #expect(abs((sketch.notch?.lowerBound ?? 0) - 771.0 / 1728) < 0.0001)
        #expect(abs((sketch.notch?.upperBound ?? 0) - 956.0 / 1728) < 0.0001)
        #expect(abs((sketch.icon?.lowerBound ?? 0) - 1133.0 / 1728) < 0.0001)
        #expect(abs((sketch.icon?.upperBound ?? 0) - 1169.5 / 1728) < 0.0001)
    }

    @Test("A screen with no notch draws no notch")
    func noNotchNoDrawing() {
        let sketch = Welcome.Sketch.of(
            bar: CGRect(x: 0, y: 0, width: 5120, height: 1440),
            notch: nil,
            icon: CGRect(x: 4900, y: 1407, width: 36, height: 33),
            iconIsVisible: true)
        #expect(!sketch.hasNotch)
        #expect(sketch.notch == nil)
        #expect(abs((sketch.icon?.lowerBound ?? 0) - 4900.0 / 5120) < 0.0001)
    }

    /// A second screen does not start at x = 0. Measuring the icon against the
    /// desktop's origin instead of the screen's would put it off the end of a
    /// sketch that is only as wide as one screen.
    @Test("It is measured against its own screen, not against the desktop")
    func theSketchIsRelativeToItsScreen() {
        let sketch = Welcome.Sketch.of(
            bar: CGRect(x: 1728, y: 0, width: 1000, height: 800),
            notch: nil,
            icon: CGRect(x: 2228, y: 780, width: 36, height: 22),
            iconIsVisible: true)
        #expect(abs((sketch.icon?.lowerBound ?? 0) - 0.5) < 0.0001)
    }

    @Test("An icon pushed off the left-hand end is pinned rather than lost")
    func anOffscreenIconIsClamped() {
        let sketch = Welcome.Sketch.of(
            bar: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            notch: nil,
            icon: CGRect(x: -842, y: 1084, width: 36, height: 33),
            iconIsVisible: false)
        #expect(sketch.icon?.lowerBound == 0)
        #expect(sketch.icon?.upperBound == 0)
    }

    @Test("A screen with no width does not take the window down with it")
    func aZeroWidthScreenIsSurvivable() {
        let sketch = Welcome.Sketch.of(bar: .zero, notch: nil, icon: nil, iconIsVisible: false)
        #expect(sketch.notch == nil)
        #expect(sketch.icon == nil)
    }

    // MARK: - What it says about finding the icon

    @Test("When macOS is drawing the icon, the window points at it")
    func aVisibleIconIsPointedAt() {
        let text = WelcomeView.findingIt(
            Welcome.Sketch(notch: 0.44...0.55, icon: 0.65...0.67, iconIsVisible: true))
        #expect(text.contains("highlighted"))
        #expect(!text.contains("not drawing it"))
    }

    /// The case this whole section exists for, and it is not an edge case: macOS
    /// never wraps status items round to the left of the notch — the first one
    /// that would cross into it is dropped and so is every one after it. The
    /// newest item is last in that queue, which is precisely an app that was
    /// installed a minute ago.
    @Test("When it is not being drawn, the window says so and says what to do")
    func ahiddenIconIsExplained() {
        let text = WelcomeView.findingIt(
            Welcome.Sketch(notch: 0.44...0.55, icon: nil, iconIsVisible: false))
        #expect(text.contains("not drawing it"))
        #expect(text.contains("notch"), "on a machine with one, that is where it went")
        #expect(text.contains("Quit something else"))
    }

    @Test("It does not blame a notch the machine does not have")
    func noNotchIsNotBlamed() {
        let text = WelcomeView.findingIt(
            Welcome.Sketch(notch: nil, icon: nil, iconIsVisible: false))
        #expect(text.contains("not drawing it"))
        #expect(!text.contains("notch"))
    }

    /// The escape hatch has to be in every version of the sentence, because the
    /// person who needs it is by definition the one who cannot reach the menu.
    /// It is only true because `applicationShouldHandleReopen` exists.
    @Test("Every version of it names the way back")
    func theWayBackIsAlwaysThere() {
        for sketch in [
            Welcome.Sketch(notch: 0.44...0.55, icon: 0.65...0.67, iconIsVisible: true),
            Welcome.Sketch(notch: 0.44...0.55, icon: nil, iconIsVisible: false),
            Welcome.Sketch(notch: nil, icon: nil, iconIsVisible: false),
        ] {
            #expect(WelcomeView.findingIt(sketch).contains("open Zonas again from Applications"))
        }
    }
}
