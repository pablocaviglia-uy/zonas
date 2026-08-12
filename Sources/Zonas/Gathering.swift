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

    /// Back to having gathered nothing, for the end of a gesture.
    mutating func forget() {
        zones = []
        releasedAt = nil
    }
}
