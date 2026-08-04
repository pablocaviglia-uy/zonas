import AppKit
import Foundation

/// A target zone, stored as fractions (0…1) of the screen's usable area rather
/// than as pixels.
///
/// Keeping them relative is what lets the same layout work just as well on the
/// laptop screen and on an external monitor of a different resolution, without
/// having to redraw it for each one.
///
/// **There is deliberately no `id`.** There was one, and Swift synthesized
/// `encode(to:)` over it, so every save put UUIDs nobody had typed into a file
/// whose whole point is being edited by hand. They were not even useful as
/// identity: a fresh one was minted on every reload of a file that didn't carry
/// them, so nothing could be tracked across a reload anyway.
///
/// In the file the handle is `name`, unique within its layout. The stable
/// identity the editor needs is a different thing, it lives in memory, and it
/// never reaches disk.
///
/// **Not `Codable`, on purpose.** Reading goes through `LayoutSyntax`, which is
/// what carries the line numbers, and writing has to render from the tree or
/// unknown keys and every comment vanish. Leaving the conformance on would leave
/// a one-line path back to both of those, and it is exactly the line somebody
/// reaches for when they are in a hurry.
struct Zone: Equatable {
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// The zone's share of the screen: the rectangle it owns.
    ///
    /// This is the **hit region**, and it is deliberately not the rectangle the
    /// window gets. Zones written to tile a screen tile it edge to edge here, so
    /// there is no band anywhere you can drop a window into and be told nothing
    /// was there.
    func rect(in area: CGRect) -> CGRect {
        CGRect(x: area.origin.x + area.width * x,
               y: area.origin.y + area.height * y,
               width: area.width * width,
               height: area.height * height)
    }

    /// The rectangle the window is actually given: the zone, minus the gap.
    ///
    /// **The preview draws this and the drop sets this**, which is the entire
    /// reason it exists. The overlay used to inset by 8 inside its own drawing
    /// code while the snap used the full rectangle, so the shape you were shown
    /// was a shape no window was ever going to be given. A preview that lies is
    /// worse than no preview: you learn to distrust it and then it is only in
    /// the way.
    /// Each side gives up half a gap to its neighbour — **except the sides that
    /// are against the edge of the screen**, which give up the margin instead.
    ///
    /// That distinction is the whole reason there are two settings. Without it,
    /// `margin: 0` would still leave half a gap all the way around the outside
    /// and there would be no way to write "flush against the edge", which is
    /// what most people want on a laptop and nobody wants on an ultrawide.
    func frame(in area: CGRect, gap: CGFloat, margin: CGFloat) -> CGRect {
        let full = rect(in: area)

        // Half a point of slack: these come out of fraction arithmetic, so a
        // zone written to reach the edge lands on it to within rounding rather
        // than exactly.
        let touching: CGFloat = 0.5
        let left = abs(full.minX - area.minX) < touching ? margin : gap / 2
        let right = abs(full.maxX - area.maxX) < touching ? margin : gap / 2
        let top = abs(full.minY - area.minY) < touching ? margin : gap / 2
        let bottom = abs(full.maxY - area.maxY) < touching ? margin : gap / 2

        let width = full.width - left - right
        let height = full.height - top - bottom

        // A zone narrower than its own gap would come back inside out, and the
        // Accessibility API would be handed a rectangle no window can occupy. A
        // zone that small is a broken file, not a layout, and leaving it alone
        // says so more usefully than a negative size would.
        //
        // The check is on these two numbers and **not** on the resulting rect,
        // because `CGRect.width` hands back the absolute value of what is
        // stored: build a rect 3.488 points wide in the wrong direction and ask
        // it how wide it is, and it cheerfully answers 3.488. A guard written
        // against the rect passes every time and protects nothing.
        guard width > 0, height > 0 else { return full }
        return CGRect(x: full.minX + left, y: full.minY + top, width: width, height: height)
    }
}

/// The key held down to summon the zones.
///
/// Option is a deliberate trap to warn people about rather than to forbid: macOS
/// has taken it for its own tiling, so choosing it makes the two features fight
/// each other over every drag.
enum Modifier: String, CaseIterable, Equatable {
    case shift, control, option, command

    var flags: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }

    /// How it reads in a menu.
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }
}

/// A set of zones that are used together.
///
/// `Equatable` is not decoration. It is what lets the file watcher ignore a
/// save that changed nothing but the formatting, what lets undo coalesce a run
/// of drags into one step, and what answers "did this actually change?" without
/// comparing rendered text. `Zone` already was; the pair only became meaningful
/// once `id` left the schema, because until then two reads of the very same
/// file compared different.
struct Layout: Equatable {
    var name: String
    var zones: [Zone]

    /// Points of air between two neighbouring windows. Each gives up half, so
    /// this is the number you actually see between them.
    var gap: CGFloat = Layout.defaultGap
    /// Points between the outermost windows and the edge of the screen.
    var margin: CGFloat = Layout.defaultMargin
    /// The key held down to summon the zones.
    var modifier: Modifier = .shift

    static let defaultGap: CGFloat = 8
    static let defaultMargin: CGFloat = 0

    /// The rectangle a window dropped in this zone is given.
    ///
    /// It lives here rather than on `Zone` because the gap and the margin belong
    /// to the layout, and a caller that has to fetch them separately is a caller
    /// that can fetch the wrong ones. §3e was that bug in miniature: the drawing
    /// code and the snapping code each knew a number, and they differed.
    func frame(of zone: Zone, in area: CGRect) -> CGRect {
        zone.frame(in: area, gap: gap, margin: margin)
    }

    /// The same rectangles, in the coordinates of a view that covers exactly
    /// `area` — which is what both the drag overlay and the editor are.
    ///
    /// It exists as one function because there are two callers and the mistake
    /// they would make separately is the same one, twice: drawing `rect` — the
    /// hit region, which tiles — instead of `frame`, the rectangle a window is
    /// actually given. That is §3e, and both places it could come back are
    /// places where nobody would notice, because a preview drawn 4 points too
    /// large on each side looks like a preview.
    ///
    /// The result is index-parallel with `zones`, so a caller that needs the
    /// names or the active one indexes both.
    func viewFrames(in area: CGRect) -> [CGRect] {
        zones.map { Coords.cgToView(frame(of: $0, in: area), filling: area) }
    }

    /// Three columns 25 / 50 / 25: the middle one for the window being worked
    /// on and the side ones for whatever is being consulted. It is the layout
    /// that pays off the most on a wide monitor, and it serves as a starting
    /// point until the zone editor exists.
    static let threeColumns = Layout(
        name: "Three Columns",
        zones: [
            Zone(name: "Left",   x: 0.00, y: 0, width: 0.25, height: 1),
            Zone(name: "Center", x: 0.25, y: 0, width: 0.50, height: 1),
            Zone(name: "Right",  x: 0.75, y: 0, width: 0.25, height: 1),
        ]
    )

    /// The zone under a point, in CG coordinates.
    ///
    /// When zones overlap, **the smallest** one containing the point wins. It
    /// is the rule that makes a layout with one big zone in the background and
    /// others on top of it usable: without it the big one would eat every
    /// target.
    ///
    /// It asks against `rect`, the hit region, and not against `frame`: the
    /// gap is something you see, never something you can fall into.
    ///
    /// This is a function of a layout and nothing else — no file, no disk, no
    /// shared instance. It used to hang off the store, which meant the only way
    /// to ask the question was to have already read a file, and it is also what
    /// lets a drag hold one layout still while the file changes underneath.
    ///
    /// It answers with an **index**, because that is the only handle that is
    /// still right when two zones are identical. The overlay used to work out
    /// which zone to highlight by comparing rectangles, which held only as long
    /// as nobody duplicated a zone — and with a config file people duplicate
    /// zones, that is what a config file is for.
    func zoneIndex(under point: CGPoint, in area: CGRect) -> Int? {
        zones.indices
            .map { (index: $0, rect: zones[$0].rect(in: area)) }
            .filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?
            .index
    }

    /// The zone itself, for the callers that do not care which one it is.
    func zone(under point: CGPoint, in area: CGRect) -> Zone? {
        zoneIndex(under: point, in: area).map { zones[$0] }
    }
}

