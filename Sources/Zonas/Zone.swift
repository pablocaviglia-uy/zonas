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

    /// The *second* key, held as well, that gathers zones instead of choosing
    /// one — so a window can be given several zones' worth of screen.
    ///
    /// Optional because it has to be possible for there to be no such key: it
    /// cannot be the same key as `modifier`, and somebody who took control for
    /// the drag itself has to be free to leave this unset rather than be told
    /// their file is broken by a default they never typed.
    var span: Modifier? = .control

    /// How far into the screen the band along the top edge reaches, in points.
    /// Zero turns it off.
    ///
    /// The depth is the file's business; the target is not. Every other
    /// rectangle a window can be given is a zone somebody wrote down, and this
    /// one appears in layouts written before it existed — drag a window up
    /// against the top of the screen and what is offered is the whole usable
    /// area.
    ///
    /// **Points and not a fraction**, unlike everything else about a zone. What
    /// the number has to be big enough for is a hand throwing a window at the
    /// top of the screen, and a hand is the same size on the laptop and on the
    /// ultrawide — the one measurement in this file that is about the person
    /// rather than about the screen.
    var maximise: CGFloat = Layout.defaultMaximise

    /// Bundle identifiers of applications Zonas keeps its hands off.
    ///
    /// A `Set` and not an array, because the only question ever asked of it is
    /// whether something is in it, and because two files that list the same
    /// applications in a different order describe the same behaviour — which is
    /// what `Layout: Equatable` is asked about every time the file is saved. The
    /// file's own order is not lost by this: the writer renders from the tree,
    /// which never stopped holding the list as it was typed.
    var ignored: Set<String> = []

    static let defaultGap: CGFloat = 8
    static let defaultMargin: CGFloat = 0

    /// Roughly the height of the menu bar, and about half a title bar. It is
    /// deep enough to hit without aiming and shallow enough that a top row of
    /// zones does not notice: on the laptop it is 2.7% of the usable height,
    /// on the ultrawide 1.7%.
    static let defaultMaximise: CGFloat = 24

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

    /// The **hit regions** in those same view coordinates: `rect`, which tiles,
    /// rather than `frame`, which does not.
    ///
    /// It is the counterpart of `viewFrames` and the two must not be confused,
    /// which is why they are named after what they answer rather than after
    /// where they are used. The editor draws frames and hit-tests these; asking
    /// the drawn rectangles instead would turn every gap into a band where
    /// clicking selects nothing and no label explains why — the same bug §3e
    /// found in the drop path, one screen further up.
    func hitRects(in area: CGRect) -> [CGRect] {
        zones.map { Coords.cgToView($0.rect(in: area), filling: area) }
    }

    /// Smallest rectangle containing the point, by index, or `nil`.
    ///
    /// **The rule that makes overlapping zones usable**, and it lives in one
    /// place because there are now two coordinate systems that need it and a
    /// second copy would be a second chance to get the tie-break backwards. A
    /// layout with one big zone behind several small ones is a thing a config
    /// file exists to let you write, and without smallest-wins the big one eats
    /// every target.
    static func smallestIndex(containing point: CGPoint, in rects: [CGRect]) -> Int? {
        rects.indices
            .filter { rects[$0].contains(point) }
            .min { rects[$0].width * rects[$0].height < rects[$1].width * rects[$1].height }
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
        Layout.smallestIndex(containing: point, in: zones.map { $0.rect(in: area) })
    }

    /// The zone itself, for the callers that do not care which one it is.
    func zone(under point: CGPoint, in area: CGRect) -> Zone? {
        zoneIndex(under: point, in: area).map { zones[$0] }
    }

    /// Several zones taken together, as **one zone**.
    ///
    /// This is the whole of the spanning feature, and the reason it costs almost
    /// nothing: a zone is four fractions of the screen, so the union of several
    /// of them is min/max arithmetic over those fractions, and what comes back
    /// is another `Zone`. Everything downstream — `frame(in:gap:margin:)` with
    /// its rule about which sides give up a gap and which give up the margin,
    /// the overlay, the drop, the clamp that keeps an oversized window on
    /// screen — works on it unchanged, because none of them ever knew where a
    /// zone came from.
    ///
    /// It is the **bounding box**, so a selection with a hole in it swallows the
    /// hole. That is what FancyZones does too, and the alternative — refusing a
    /// non-contiguous selection — would mean explaining a rule at the exact
    /// moment somebody is mid-drag with two keys held down.
    ///
    /// The name is joined in **file order** rather than in the order the zones
    /// were visited, so the same three zones always produce the same label and
    /// the same line in the log however you swept across them.
    func union(of indices: Set<Int>) -> Zone? {
        let chosen = indices.sorted().filter(zones.indices.contains).map { zones[$0] }
        guard let first = chosen.first else { return nil }
        guard chosen.count > 1 else { return first }

        let minX = chosen.map(\.x).min()!
        let minY = chosen.map(\.y).min()!
        let maxX = chosen.map { $0.x + $0.width }.max()!
        let maxY = chosen.map { $0.y + $0.height }.max()!

        return Zone(name: chosen.map(\.name).joined(separator: " + "),
                    x: minX,
                    y: minY,
                    width: maxX - minX,
                    height: maxY - minY)
    }

    /// The whole usable area, as a zone that is in nobody's file.
    ///
    /// Being a `Zone` is the entire cost of maximising, the same trick `union`
    /// plays from the other direction: `frame(of:in:)` gives it the margin on
    /// all four sides because it touches all four edges, the overlay draws it,
    /// the drop sets it, and Stage 4's clamp keeps it on the screen — none of
    /// which needed a line for it.
    ///
    /// **The name is what the overlay writes across the screen**, and it is not
    /// "Full Screen" on purpose. On a Mac that means the green button: a
    /// separate Space, a hidden menu bar and a window no tiler can then move.
    /// Promising it in fifteen-point type and doing something else would be the
    /// preview lying about the drop, which is §3e with words instead of
    /// rectangles.
    static let maximised = Zone(name: "Maximised", x: 0, y: 0, width: 1, height: 1)

    /// The strip along the top of the screen where a drop maximises instead of
    /// filling a zone, or `nil` when the file has turned it off.
    ///
    /// **It reaches above the usable area, over the menu bar**, and that is not
    /// generosity — it is where the pointer actually ends up. macOS stops the
    /// window when its title bar reaches the menu bar but it does not stop the
    /// pointer, so somebody throwing a window at the top of the screen finishes
    /// with the cursor in a strip no zone can ever cover. Those points are free:
    /// nothing else in the app can be aimed at from there.
    ///
    /// It spans the whole width of the **screen** rather than of the usable
    /// area, so a Dock on the left does not carve a dead corner out of the top
    /// edge. `min` is what makes the arithmetic safe rather than a guard: the
    /// usable area is inside the screen, so the top of the band is at or above
    /// the top of the area and the height cannot come out negative.
    ///
    /// This is a **hit region**, like `Zone.rect` and unlike `Zone.frame`. What
    /// the window is given is `frame(of: Layout.maximised, in:)`, which is the
    /// usable area and has nothing to do with this rectangle.
    func maximiseBand(of screen: CGRect, usable area: CGRect) -> CGRect? {
        guard maximise > 0 else { return nil }
        // CG coordinates: the top of the screen is the *smallest* y.
        let top = min(screen.minY, area.minY)
        return CGRect(x: screen.minX,
                      y: top,
                      width: screen.width,
                      height: area.minY + maximise - top)
    }

    /// The rectangle a selection resolves to, or `nil` when nothing is chosen.
    ///
    /// Both callers that matter come through here — the overlay draws this and
    /// the drop applies it — for the same reason `frame(of:in:)` exists. A
    /// second answer to "what is about to happen" is a second chance for the
    /// preview to lie.
    func target(of selection: Selection) -> Zone? {
        switch selection {
        case .maximised: return Layout.maximised
        case .zones(let indices): return union(of: indices)
        }
    }

    /// Whether this application is one the file says to leave alone.
    ///
    /// **Matching is exact**, on the bundle identifier and nothing else. An
    /// identifier is already a stable, exact handle — matching on the localized
    /// application name instead, which is what one of the tilers does, breaks
    /// for everybody whose Mac is not in English, and this repository's author
    /// works in Spanish: "System Settings" is "Ajustes del Sistema" here.
    ///
    /// Patterns are deliberately not supported *yet* rather than ruled out. A
    /// bundle identifier is letters, digits, hyphens and dots, so an entry
    /// containing `*` cannot collide with a real one and the door stays open to
    /// give it a meaning later without changing what any existing file means.
    ///
    /// A process with no bundle identifier at all cannot be excluded, and there
    /// are some — the Android emulator on this machine is one. Saying so here is
    /// cheaper than the bug report.
    func ignores(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignored.contains(bundleID)
    }
}

/// What a drag has chosen, and therefore what the overlay draws and what the
/// drop applies.
///
/// It was a `Set<Int>` — indices into the layout — until there was a target the
/// file does not contain. An index cannot name the whole screen, and both ways
/// of pretending it could are worse than a type: a sentinel index leaves every
/// `contains` in the app one forgotten guard away from drawing a zone that is
/// not there, and appending a synthetic zone to the layout makes the overlay
/// draw the whole screen as one more box among the others, every drag, whether
/// or not anybody is near the top edge.
enum Selection: Equatable {

    /// Zones from the file, by index. Empty is a real answer and not a mistake:
    /// it is the cursor over a part of the screen no zone covers.
    case zones(Set<Int>)

    /// The band along the top edge.
    ///
    /// Deliberately not `.zones` holding every index. The union of every zone
    /// in a file is the whole screen only for a layout that happens to tile it,
    /// and "maximise" cannot mean something different for a layout with a hole
    /// in it.
    case maximised

    /// The zones of the file this selection covers, which is none of them when
    /// the whole screen is the target. The overlay asks, to know which boxes it
    /// would otherwise draw twice.
    var gathered: Set<Int> {
        if case .zones(let indices) = self { return indices }
        return []
    }
}
