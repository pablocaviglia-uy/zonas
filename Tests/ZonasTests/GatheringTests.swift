import Foundation
import Testing
@testable import Zonas

/// Somewhere the cursor can be. Only the distances between these matter.
private let parked = CGPoint(x: 800, y: 400)
private func near(_ p: CGPoint, by d: CGFloat) -> CGPoint {
    CGPoint(x: p.x + d, y: p.y)
}

@Suite("Gathering zones with the span key")
struct GatheringTests {

    @Test("Without the key, the answer is the zone under the cursor")
    func plainGesture() {
        var gathering = Gathering()

        #expect(gathering.selection(under: 1, at: parked, spanHeld: false) == [1])
        #expect(gathering.selection(under: 2, at: parked, spanHeld: false) == [2])
        #expect(gathering.selection(under: nil, at: parked, spanHeld: false) == [])
    }

    @Test("With the key held, every zone the cursor crosses joins")
    func sweepGathers() {
        var gathering = Gathering()

        #expect(gathering.selection(under: 0, at: parked, spanHeld: true) == [0])
        #expect(gathering.selection(under: 1, at: parked, spanHeld: true) == [0, 1])
        #expect(gathering.selection(under: 2, at: parked, spanHeld: true) == [0, 1, 2])
    }

    /// Additive, and this is the test that says so on purpose: toggling on
    /// re-entry would mean dragging back across your own selection destroys it.
    @Test("Crossing a zone a second time does not remove it")
    func gatheringIsAdditive() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true)

        #expect(gathering.selection(under: 0, at: parked, spanHeld: true) == [0, 1])
    }

    /// The report this rule exists for. Both keys are released together, the
    /// span key's event lands first, and the selection has to still be there
    /// when the modifier's event arrives to commit it.
    @Test("Letting go of the key keeps what was gathered while the hand is still")
    func releasingTheKeyKeepsTheSelection() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true)

        #expect(gathering.selection(under: 1, at: parked, spanHeld: false) == [0, 1])
    }

    @Test("A tremble is not the hand moving on")
    func jitterKeepsTheSelection() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: false)

        #expect(gathering.selection(under: 1, at: near(parked, by: 3), spanHeld: false) == [0, 1])
    }

    /// The way out of a sweep that picked up one zone too many: overshoot, let
    /// go, carry on.
    @Test("Moving on after letting go goes back to one zone")
    func movingOnStartsOver() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: false)

        #expect(gathering.selection(under: 2, at: near(parked, by: 40), spanHeld: false) == [2])
        #expect(gathering.zones.isEmpty)
    }

    /// The distance is measured from where the key came up, not from the last
    /// event. Measured event to event, a slow drift never exceeds the slop and
    /// the gathering would outlive the gesture that made it.
    @Test("The slop is spent once, not on every event")
    func distanceIsMeasuredFromTheRelease() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 0, at: parked, spanHeld: false)

        #expect(gathering.selection(under: 0, at: near(parked, by: 5), spanHeld: false) == [0])
        #expect(gathering.selection(under: 1, at: near(parked, by: 10), spanHeld: false) == [1])
    }

    /// Pressing it again without having moved is a finger that slipped, not a
    /// new selection — the sweep carries on from where it was.
    @Test("Pressing the key again while the selection stands carries on")
    func pressingAgainResumes() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 0, at: parked, spanHeld: false)

        #expect(gathering.selection(under: 1, at: parked, spanHeld: true) == [0, 1])
    }

    /// And once the hand has moved on, the selection is gone, so the key going
    /// down again starts an empty one.
    @Test("Pressing the key again after moving on starts a new selection")
    func pressingAgainAfterMovingStartsFresh() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 0, at: parked, spanHeld: false)
        _ = gathering.selection(under: 2, at: near(parked, by: 40), spanHeld: false)

        #expect(gathering.selection(under: 2, at: near(parked, by: 40), spanHeld: true) == [2])
    }

    /// A drop and a suspension both go through here, and a gathering that
    /// outlived its drag would be handed to the next window moved.
    @Test("Forgetting the drag forgets the gathering")
    func forgetting() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true)
        gathering.forget()

        #expect(gathering.zones.isEmpty)
        #expect(gathering.selection(under: 2, at: parked, spanHeld: false) == [2])
    }

    /// Nothing gathered and nothing under the cursor is nothing selected — not
    /// an empty gathering that the drop would read as a zone.
    @Test("The gap between two screens selects nothing")
    func nothingUnderTheCursor() {
        var gathering = Gathering()

        #expect(gathering.selection(under: nil, at: parked, spanHeld: true) == [])
        #expect(gathering.selection(under: nil, at: parked, spanHeld: false) == [])
    }
}

/// The other half of the same answer: the band along the top edge, which is the
/// one thing that beats the zone under the cursor.
@Suite("Maximising from the top edge")
struct BandSelectionTests {

    @Test("In the band, with nothing gathered, the whole screen is the target")
    func theBandWins() {
        var gathering = Gathering()

        #expect(gathering.selection(under: 0, at: parked, spanHeld: false, inBand: true)
                == .maximised)
    }

    @Test("Outside it, the zone under the cursor is, exactly as before")
    func outsideItNothingChanged() {
        var gathering = Gathering()

        #expect(gathering.selection(under: 0, at: parked, spanHeld: false, inBand: false)
                == .zones([0]))
        #expect(gathering.selection(under: nil, at: parked, spanHeld: false, inBand: false)
                == .zones([]))
    }

    /// Spanning builds a rectangle out of zones and the whole screen is not one
    /// of them. Without this a sweep along the top row would keep turning into
    /// "maximise" under the hand doing it, with no combination of keys able to
    /// stop it — and there would be no way to aim at the zones the band covers.
    @Test("With the span key held there is no band")
    func theSpanKeyTurnsItOff() {
        var gathering = Gathering()

        #expect(gathering.selection(under: 0, at: parked, spanHeld: true, inBand: true)
                == .zones([0]))
        #expect(gathering.selection(under: 1, at: parked, spanHeld: true, inBand: true)
                == .zones([0, 1]), "and the zone under the band joins the sweep")
    }

    /// The rule that lets both keys be let go of at once, defended from the new
    /// direction. What was gathered survives the span key for eight points, it
    /// is what is on screen, and the band must not replace it underneath
    /// somebody who is a few milliseconds from releasing the modifier.
    @Test("A standing gathering is not taken away by the band")
    func aStandingGatheringSurvives() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true, inBand: true)
        _ = gathering.selection(under: 1, at: parked, spanHeld: true, inBand: true)

        #expect(gathering.selection(under: 1, at: parked, spanHeld: false, inBand: true)
                == .zones([0, 1]))
    }

    /// And once the hand has moved on, the gathering is gone and the band is
    /// back — the escape hatch works from up here too.
    @Test("Once the hand moves on, the band takes over again")
    func andIsBackOnceTheHandMovesOn() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true, inBand: true)
        _ = gathering.selection(under: 0, at: parked, spanHeld: false, inBand: true)

        #expect(gathering.selection(under: 0, at: near(parked, by: 40), spanHeld: false,
                                    inBand: true) == .maximised)
    }

    /// The slop is measured from where the cursor was when the key came up, so
    /// the gathering has to be asked on every event whatever the answer turns
    /// out to be. An early return for a cursor in the band would freeze it for
    /// as long as somebody held the pointer up there, and the escape hatch
    /// above would stop working after a trip through the top of the screen.
    @Test("The band does not stop the gathering's clock")
    func theGatheringIsStillAsked() {
        var gathering = Gathering()

        _ = gathering.selection(under: 0, at: parked, spanHeld: true, inBand: false)
        _ = gathering.selection(under: 0, at: parked, spanHeld: false, inBand: false)
        // Every one of these is inside the band, where the answer never depends
        // on the gathering — and the last of them still has to have moved on.
        _ = gathering.selection(under: 0, at: parked, spanHeld: false, inBand: true)
        _ = gathering.selection(under: 0, at: near(parked, by: 40), spanHeld: false, inBand: true)

        #expect(gathering.isEmpty)
    }
}
