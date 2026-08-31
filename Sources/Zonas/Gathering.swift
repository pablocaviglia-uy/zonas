import Foundation

/// The zones the span key has gathered, and the rule for when it lets go of
/// them.
///
/// It is a type of its own rather than two fields inside `DragMonitor` because
/// `DragMonitor` cannot be unit-tested — it only exists with a live tap over
/// every mouse event on the session, and the only way to exercise it is to post
/// events at the real machine and read the log. This is the part of the gesture
/// with the edge cases in it, so it lives where a test can reach it.
struct Gathering {

    /// How far the cursor has to travel, once the span key is up, before what
    /// was gathered is dropped.
    ///
    /// It used to be zero — the key came up, the selection went — and zero is
    /// only right if the two keys are released one at a time and in the correct
    /// order. Letting go of both at once is what "done, put it there" feels
    /// like, and it sends two `flagsChanged` events a few milliseconds apart in
    /// whichever order the hardware saw them: with the span key first, the
    /// gathering was already thrown away by the time the modifier's event
    /// arrived to commit it, and the window landed in whatever single zone the
    /// cursor happened to be over. Same gesture, different outcome, decided by
    /// which finger lifted first.
    ///
    /// Eight points is the number `DragMonitor` uses to tell a drag from a click
    /// with an unsteady hand, and the question here is the same one: is this the
    /// hand moving on, or the hand not being a clamp.
    private static let slop: CGFloat = 8

    /// The zones gathered so far, by index into the layout the drag froze.
    private(set) var zones: Set<Int> = []

    /// Whether anything is standing.
    ///
    /// The band along the top edge asks before it claims a drop. A gathering
    /// that outlived the span key coming up is still the rectangle on screen,
    /// and the band taking it away from under somebody who is about to let go
    /// of the modifier would undo the whole of the rule below.
    var isEmpty: Bool { zones.isEmpty }

    /// Where the cursor was when the span key came up, for as long as what was
    /// gathered is still standing. `nil` while the key is held, and `nil` again
    /// once the hand has moved on.
    private var releasedAt: CGPoint?

    /// The zones the drop will use: the gathering while the span key is held,
    /// and the single zone under the cursor when it is not.
    ///
    /// `index` is the zone under the cursor, if the cursor is over one at all.
    mutating func selection(under index: Int?, at point: CGPoint, spanHeld: Bool) -> Set<Int> {
        if spanHeld {
            // Gathering is additive, and passing back over a zone does not
            // remove it: a sweep has to be predictable, and toggling on
            // re-entry means dragging back across your own selection destroys
            // it. What makes additive survivable is the way out below.
            releasedAt = nil
            if let index { zones.insert(index) }
            return zones
        }

        guard !zones.isEmpty else { return index.map { [$0] } ?? [] }

        // The span key is up with zones still gathered. They are kept — for
        // now. This is either somebody finishing the gesture, or somebody
        // starting the selection over, and at this instant the two look
        // identical. The next thing the hand does is what tells them apart, so
        // the answer waits for it.
        let anchor = releasedAt ?? point
        releasedAt = anchor
        guard hypot(point.x - anchor.x, point.y - anchor.y) > Gathering.slop else {
            return zones
        }

        // It moved on. That is the way out of a sweep that picked up one zone
        // too many — overshoot, let go, carry on — and it costs a twitch of the
        // wrist where it used to cost nothing. What it buys is that letting go
        // of both keys together, in either order, places the window on what the
        // screen was showing.
        zones = []
        releasedAt = nil
        return index.map { [$0] } ?? []
    }

    /// The same answer with the band along the top edge folded in: what the
    /// drop will actually use.
    ///
    /// It lives here and not in `DragMonitor` for the reason the rest of this
    /// type does — `DragMonitor` needs a live tap over every mouse event on the
    /// session and cannot be tested by anything but a person at the machine —
    /// and because both conditions that keep the band from stealing a drop are
    /// about state this type owns.
    ///
    /// **While the span key is held the band is not there at all.** Spanning
    /// builds a rectangle out of zones and the whole screen is not one of them,
    /// so a sweep along the top row would otherwise keep turning into
    /// "maximise" under somebody's hand with no way to say no. That it also
    /// gives a way to reach the zones the band covers is the same rule paying
    /// twice.
    ///
    /// **And it does not take a standing gathering away.** Zones gathered
    /// before the key came up survive the release until the hand moves on —
    /// that is what lets both keys be let go of at once — and they are what is
    /// on screen. The band claiming the drop inside that window would land the
    /// window somewhere nobody was looking, which is the bug the slop above
    /// exists to have fixed, arriving through a new door.
    mutating func selection(under index: Int?,
                            at point: CGPoint,
                            spanHeld: Bool,
                            inBand: Bool) -> Selection {
        // Asked first and unconditionally, whatever the answer turns out to be:
        // the rules above are about what the hand has been doing rather than
        // about this one point, and the slop is measured from where the cursor
        // was when the key came up. Skipping the call for a cursor in the band
        // would freeze it for as long as somebody held the pointer up there.
        let chosen = selection(under: index, at: point, spanHeld: spanHeld)

        guard inBand, !spanHeld, isEmpty else { return .zones(chosen) }
        return .maximised
    }

    /// Back to having gathered nothing, for the end of a gesture.
    mutating func forget() {
        zones = []
        releasedAt = nil
    }
}
