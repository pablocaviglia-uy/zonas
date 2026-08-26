import AppKit

/// Which screen the ⌘Tab application switcher opens on.
///
/// **It opens on the screen the Dock is on.** Not the main display, not the
/// display with the frontmost window, not the display the pointer is on, and —
/// this is the trap — not the display macOS calls the *active menu bar
/// display*. The switcher is a window owned by the Dock process, and it is
/// drawn wherever that process currently lives.
///
/// The trap is worth the paragraph, because the next person to look at this
/// will find `SLSCopyActiveMenuBarDisplayIdentifier` in SkyLight, watch it
/// change exactly when the menu bar moves between screens, and conclude it is
/// the answer. It is not, and the two agree often enough to look like it. The
/// run that separates them:
///
/// ```
///                                  dock       activeBar   switcher
/// start                            ULTRA      ULTRA       ULTRA
/// after push Dock->ULTRA           ULTRA      ULTRA       ULTRA
/// after click BUILTIN menu bar     ULTRA      BUILTIN     ULTRA     ← disagree
/// after push Dock->BUILTIN         BUILTIN    BUILTIN     BUILTIN
/// after click ULTRA menu bar       BUILTIN    ULTRA       BUILTIN   ← disagree
/// after push Dock->ULTRA           ULTRA      ULTRA       ULTRA
/// ```
///
/// Six for six on the Dock, four for six on the menu bar.
///
/// **Moving it is a pointer gesture, and only a pointer gesture.** Everything
/// with an API on it was tried and none of it works:
///
/// - `SLSSetActiveMenuBarDisplayIdentifier` moves the wrong thing, and does not
///   even do that: it returns `0` for success and changes nothing, on three
///   argument spellings, read back from a fresh connection.
/// - `SLSSetDockRectWithReason` *is* accepted — the rect reads back changed —
///   and the Dock does not move. It edits the WindowServer's cached copy of
///   where the Dock is, not the Dock.
/// - Warping the pointer onto a screen, `NSRunningApplication.activate` on an
///   app whose windows are there, and a real key window of our own on it: none
///   of them move the Dock.
///
/// What moves it is what a person does: push the pointer against the bottom
/// edge of the screen you want it on. Synthesised, that is a short run of real
/// `.mouseMoved` events walking into the edge — **and it has to be a walk**. A
/// warp straight to the edge does nothing, and so does a burst of events posted
/// at the edge with no approach: measured, 0 out of 5 for arrival, 12 out of 12
/// for a 40-point approach in 8-point steps. The Dock is watching for pressure,
/// not for position.
///
/// The price is 1.5 ms with the pointer somewhere the user did not put it, and
/// ~65 ms until the Dock has settled — measured end to end in the running app,
/// where one ⌘ press moves it back 3 times out of 3. The Dock does not stay
/// revealed.
///
/// This half has no system calls in it, which is what makes it testable.
/// `DockDisplay` is the half that talks to the system.
enum Switcher {

    // MARK: - The pin

    /// `UserDefaults` and not the layout file: Rule 3. Which of *this machine's*
    /// monitors owns the switcher is not something anybody wants to find in a
    /// layout committed to a dotfiles repo and applied at a different desk.
    static let pinnedKey = "switcherScreen"

    /// The display the switcher is pinned to, or `nil` for "wherever the Dock
    /// happens to be", which is what everybody has today.
    ///
    /// A display UUID, and not a name and not a `CGDirectDisplayID`. Names
    /// repeat the moment somebody buys a second identical monitor, and display
    /// IDs are handed out afresh when a monitor is unplugged and plugged back
    /// in — which is one of the two ways this drifts in the first place.
    static func pinned(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: pinnedKey)
    }

    static func pin(_ uuid: String?, _ defaults: UserDefaults = .standard) {
        if let uuid {
            defaults.set(uuid, forKey: pinnedKey)
        } else {
            defaults.removeObject(forKey: pinnedKey)
        }
    }

    /// Whether the switcher is somewhere the user did not ask for.
    ///
    /// No pin is not a correction owed, it is the absence of an opinion. And a
    /// Dock whose screen cannot be read is not a correction owed either: the
    /// move is a pointer gesture that cannot be undone, and firing it blind
    /// would drag somebody's cursor across the desk on a guess.
    static func shouldCorrect(pinned: String?, current: String?) -> Bool {
        guard let pinned, let current else { return false }
        return pinned != current
    }

    // MARK: - The gesture

    /// Which edge of a screen the Dock lives on.
    ///
    /// **Only `bottom` can be moved, and that is a measurement rather than a
    /// simplification.** With the Dock set to the left, nine attempts to move it
    /// between two displays failed: its own left edge, at three heights
    /// including the stretch with no neighbouring display beyond it; the bottom,
    /// top and right edges; and the left edge again with deltas up to −60 over a
    /// hundred events. A person can do this with a real mouse. Synthesised
    /// movement cannot, and the reason was not found.
    ///
    /// So the enum exists to *recognise* the two cases this cannot serve, not to
    /// serve them. The alternative — try anyway and fail — costs a pointer
    /// dragged across the desk for nothing every time somebody presses ⌘.
    enum Edge: String {
        case bottom, left, right

        /// What macOS has the Dock set to right now.
        ///
        /// Read from the Dock's own domain rather than guessed. Verified against
        /// the real domain: unset reads `bottom`, and writing `left` and `right`
        /// reads back as each of them.
        static var current: Edge {
            reading(UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation"))
        }

        /// The fallback, split out so it can be held still.
        ///
        /// **Absent has to mean bottom**, and absent is the normal case: macOS
        /// does not write `orientation` at all until somebody moves the Dock, so
        /// on a machine that has never touched it there is no key to read. Get
        /// this wrong in the other direction and the feature refuses on every Mac
        /// in the world while looking perfectly reasonable in the source.
        ///
        /// `top` is not a case because macOS does not offer it.
        static func reading(_ raw: String?) -> Edge {
            raw.flatMap(Edge.init(rawValue:)) ?? .bottom
        }
    }

    /// How far back from the edge the pointer starts.
    ///
    /// Forty points was the shortest run that still worked every time. It is a
    /// straight trade: this distance is how far the pointer visibly jumps, and
    /// arriving at the edge without a run at all moves nothing.
    static let approachDistance: CGFloat = 40

    /// How big a step to take. Each step is one `.mouseMoved` event.
    static let approachStep: CGFloat = 8

    /// The path the pointer takes into the bottom of a screen, in CG
    /// coordinates: **where the run starts, then every step of it**, ending on
    /// the edge itself.
    ///
    /// The first point is the standing start, not a step — `DockDisplay.push`
    /// puts the pointer there and posts the rest as movement. So the count is
    /// `steps + 1` and the travel is `approachDistance`, which is the arithmetic
    /// this got wrong: written as `(1...steps)` the first point was already 8
    /// points into the run, and the Dock was handed 32 points over 4 events
    /// instead of the 40 over 5 that was measured. It worked anyway — which is
    /// the bad kind of bug, the one where the number in the comment and the
    /// number in the wire disagree and nothing complains.
    ///
    /// It runs down the middle, which is where the Dock is drawn and, more to
    /// the point, the part of the edge furthest from the corners — the corners
    /// are Mission Control's, and walking into one of those would be a very
    /// surprising thing for a window manager to do on its own.
    static func approach(intoBottomOf frame: CGRect) -> [CGPoint] {
        let steps = Int((approachDistance / approachStep).rounded(.up))
        guard steps > 0, frame.height > approachDistance else { return [] }

        // CG coordinates: `minY` is the top of the screen and `maxY` the bottom,
        // so the last row of pixels is `maxY - 1`. Aiming at `maxY` itself is a
        // point on the screen below, or on nothing at all.
        return (0...steps).map { i in
            let fromEdge = approachDistance - min(CGFloat(i) * approachStep, approachDistance)
            return CGPoint(x: frame.midX, y: frame.maxY - 1 - fromEdge)
        }
    }
}
