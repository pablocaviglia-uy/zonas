import Foundation
import Testing
@testable import Zonas

@Suite("Preview styling disappears before the live picture hands off")
struct PreviewDismissalTests {
    private let neutralAt = PreviewDismissal.effectsDuration + PreviewDismissal.neutralDuration

    @Test("The transition begins with full styling and an opaque picture")
    func startsOpaque() {
        var dismissal = PreviewDismissal()
        let appearance = dismissal.advance(elapsed: 0, windowIsReady: true)
        #expect(appearance.effects == 1)
        #expect(appearance.picture == 1)
        #expect(!appearance.isComplete)
    }

    @Test("A negative clock offset cannot brighten the selection")
    func negativeTimeStartsAtZero() {
        var dismissal = PreviewDismissal()
        let appearance = dismissal.advance(elapsed: -0.1, windowIsReady: true)
        #expect(appearance.effects == 1)
        #expect(appearance.picture == 1)
    }

    @Test("Only the styling changes during the first phase")
    func stylingFirst() {
        var dismissal = PreviewDismissal()
        let appearance = dismissal.advance(elapsed: PreviewDismissal.effectsDuration / 2,
                                           windowIsReady: true)
        #expect(abs(appearance.effects - 0.5) < 0.000_001)
        #expect(appearance.picture == 1)
        #expect(!appearance.isComplete)
    }

    @Test("The live image remains opaque when the blue frame has disappeared")
    func neutralHold() {
        var dismissal = PreviewDismissal()
        for time in [PreviewDismissal.effectsDuration, neutralAt - 0.001] {
            let appearance = dismissal.advance(elapsed: time, windowIsReady: true)
            #expect(appearance.effects == 0)
            #expect(appearance.picture == 1)
            #expect(!appearance.isComplete)
        }
    }

    @Test("The second phase reveals the real window only after a neutral image")
    func pictureFadesAfterNeutralHold() {
        var dismissal = PreviewDismissal()
        let neutral = dismissal.advance(elapsed: neutralAt, windowIsReady: true)
        #expect(neutral.effects == 0)
        #expect(neutral.picture == 1)
        let halfway = dismissal.advance(elapsed: neutralAt + PreviewDismissal.pictureDuration / 2,
                                        windowIsReady: true)
        #expect(halfway.effects == 0)
        #expect(abs(halfway.picture - 0.5) < 0.000_001)
        #expect(!halfway.isComplete)
        let complete = dismissal.advance(elapsed: neutralAt + PreviewDismissal.pictureDuration + 0.001,
                                          windowIsReady: true)
        #expect(complete.effects == 0)
        #expect(complete.picture == 0)
        #expect(complete.isComplete)
    }

    @Test("An unfocused target retains the neutral preview before the deadline")
    func waitsForActivation() {
        var dismissal = PreviewDismissal()
        for time in [neutralAt, 0.4, PreviewDismissal.activationDeadline - 0.001] {
            let appearance = dismissal.advance(elapsed: time, windowIsReady: false)
            #expect(appearance.effects == 0)
            #expect(appearance.picture == 1)
            #expect(!appearance.isComplete)
        }
    }

    @Test("Late activation starts a fresh picture fade rather than skipping it")
    func lateActivationStartsItsOwnFade() {
        var dismissal = PreviewDismissal()
        _ = dismissal.advance(elapsed: neutralAt, windowIsReady: false)
        let activatedAt: TimeInterval = 0.4
        let start = dismissal.advance(elapsed: activatedAt, windowIsReady: true)
        #expect(start.effects == 0)
        #expect(start.picture == 1)
        let halfway = dismissal.advance(elapsed: activatedAt + PreviewDismissal.pictureDuration / 2,
                                        windowIsReady: true)
        #expect(abs(halfway.picture - 0.5) < 0.000_001)
    }

    @Test("Failure to activate cannot leave a preview covering the desktop forever")
    func activationDeadlineBoundsTheWait() {
        var dismissal = PreviewDismissal()
        _ = dismissal.advance(elapsed: neutralAt, windowIsReady: false)
        let start = dismissal.advance(elapsed: PreviewDismissal.activationDeadline,
                                      windowIsReady: false)
        #expect(start.effects == 0)
        #expect(start.picture == 1)
        let complete = dismissal.advance(
            elapsed: PreviewDismissal.activationDeadline + PreviewDismissal.pictureDuration + 0.001,
            windowIsReady: false)
        #expect(complete.picture == 0)
        #expect(complete.isComplete)
    }

    @Test("A delayed timer still renders the neutral preview before fading it")
    func delayedTickDoesNotSkipThePictureFade() {
        var dismissal = PreviewDismissal()
        let delayedAt = PreviewDismissal.activationDeadline + 0.2
        let start = dismissal.advance(elapsed: delayedAt, windowIsReady: false)
        #expect(start.effects == 0)
        #expect(start.picture == 1)
        #expect(!start.isComplete)
        let complete = dismissal.advance(elapsed: delayedAt + PreviewDismissal.pictureDuration + 0.001,
                                          windowIsReady: false)
        #expect(complete.isComplete)
    }

    @Test("A focus change during the picture fade cannot restart or reverse it")
    func readinessCannotRestartTheFade() {
        var dismissal = PreviewDismissal()
        _ = dismissal.advance(elapsed: neutralAt, windowIsReady: true)
        let halfway = dismissal.advance(elapsed: neutralAt + PreviewDismissal.pictureDuration / 2,
                                        windowIsReady: false)
        #expect(abs(halfway.picture - 0.5) < 0.000_001)
        let complete = dismissal.advance(elapsed: neutralAt + PreviewDismissal.pictureDuration + 0.001,
                                          windowIsReady: false)
        #expect(complete.isComplete)
        let stillComplete = dismissal.advance(elapsed: neutralAt + 1, windowIsReady: true)
        #expect(stillComplete.effects == 0)
        #expect(stillComplete.picture == 0)
        #expect(stillComplete.isComplete)
    }
}
