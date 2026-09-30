import AppKit

/// What is drawn around the chosen window while ⌥Tab is up: the rest of the
/// screen pushed back, and two lines through each of the window's edges.
///
/// **The problem it answers is competition, not visibility.** The ring is
/// already bright, and on a desk with twenty windows open it is bright next to
/// twenty other bright things — so every way of making it louder (a thicker
/// stroke, a stronger wash) is fighting the noise on the noise's terms, and
/// gets a little less effective with each window opened. Dimming everything
/// else is the only effect here whose strength *grows* with the number of
/// windows, because it is the number of windows that it removes.
///
/// This half is the geometry and the switch, with no window in it, which is
/// what lets a test state the answer. `WindowHighlight` is the drawing.
enum Spotlight {

    // MARK: - The switch

    /// `UserDefaults` and not the layout file: Rule 3. Whether ⌥Tab dims the
    /// desk is this machine's business, and a layout committed to a dotfiles
    /// repo has no business carrying one person's taste in screen furniture to
    /// every desk they sit at.
    static let key = "switcherSpotlight"

    /// **`object(forKey:)` and not `bool(forKey:)`**, for the reason
    /// `WindowPreviews` spells out: `bool` answers `false` for a key nobody has
    /// written, which would turn this off for everybody who has never opened
    /// the menu — the one place where no opinion and an opinion of "no" are
    /// different things.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setOn(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }

    // MARK: - How dark

    /// How much black goes over everything that is not the chosen window.
    ///
    /// The editor's scrim is 0.6 and this is deliberately lighter. They are
    /// asking for different things: the editor wants the desktop present but
    /// out of the way for as long as you are drawing zones, where this is up
    /// for the length of a keypress and has to leave the other windows
    /// recognisable — you are choosing between them, so a scrim that made them
    /// all one dark rectangle would take away the thing being chosen from.
    static let dim: CGFloat = 0.45

    /// The guides are far fainter than the ring, and that is the whole of their
    /// design. They are for the corner of the eye on a 5120-point monitor,
    /// where the ring can land a metre from where you are looking; anything
    /// strong enough to read head-on would draw the eye to a line instead of to
    /// the window the line is pointing at.
    static let guideAlpha: CGFloat = 0.35

    /// Two points, and the reason is the pixel grid rather than taste. A
    /// one-point line centred on a window edge at a whole coordinate spans
    /// 379.5 to 380.5, so on the 1× ultrawide it lands half in each of two
    /// pixel columns and antialiasing halves it: measured against the scrim it
    /// came out at alpha 0.546 where 0.64 was asked for, which on a monitor this
    /// wide is the difference between a guide and a smudge. Two points centred
    /// on the same edge cover both columns outright.
    static let guideThickness: CGFloat = 2

    // MARK: - The guides

    /// Two lines through the window's vertical edges and two through its
    /// horizontal ones, each spanning the whole screen.
    ///
    /// The shape is a camera's framing guide, and it is picked over the obvious
    /// alternative — four short ticks reaching *out* from the corners — because
    /// a line that runs off the edge of the screen can be picked up anywhere
    /// along its length. A tick can only be found by already looking near the
    /// window, which is the thing you do not yet know how to do.
    ///
    /// - Parameters:
    ///   - hole: the chosen window, in the view's coordinates.
    ///   - bounds: the view, which covers exactly one screen.
    /// - Returns: the lines to fill, in drawing order, **dropping any whose
    ///   edge falls outside this screen**. A window can straddle two monitors,
    ///   and on the screen holding its right-hand half the left edge is not
    ///   somewhere a line belongs — it would come out pinned to the bezel,
    ///   pointing at a window edge that is on the other monitor.
    static func guides(around hole: CGRect,
                       in bounds: CGRect,
                       thickness: CGFloat = guideThickness) -> [CGRect] {
        // Nothing at all for a screen the window is not on, and this guard is
        // not the same question as the two below it. Asked only per edge, a
        // window on the monitor to the right at the same *height* as this one
        // still passed both of its horizontal edges — so the laptop got two
        // full-width lines through it pointing at a window that was not there.
        // Caught by a test, which is the only way it was ever going to be:
        // it needs two monitors to happen at all.
        guard holds(hole, in: bounds) else { return [] }

        var lines: [CGRect] = []
        let half = thickness / 2

        for x in [hole.minX, hole.maxX] where x >= bounds.minX && x <= bounds.maxX {
            lines.append(CGRect(x: x - half, y: bounds.minY,
                                width: thickness, height: bounds.height))
        }
        for y in [hole.minY, hole.maxY] where y >= bounds.minY && y <= bounds.maxY {
            lines.append(CGRect(x: bounds.minX, y: y - half,
                                width: bounds.width, height: thickness))
        }
        return lines
    }

    /// Whether this screen has anything to draw but scrim.
    ///
    /// A window lives on one screen, usually. The others get the dimming and
    /// nothing else — no ring, no guides, no picture — and asking this is what
    /// keeps the ring off a monitor the window is not on.
    static func holds(_ hole: CGRect, in bounds: CGRect) -> Bool {
        hole.intersects(bounds)
    }
}
