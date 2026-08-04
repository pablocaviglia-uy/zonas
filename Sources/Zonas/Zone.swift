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
struct Zone: Codable, Equatable {
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
    func frame(in area: CGRect, gap: CGFloat = Zone.gap) -> CGRect {
        let full = rect(in: area)
        // insetBy hands back CGRect.null when the inset eats the rectangle, and
        // CGRect.null's origin is infinity — which would go straight to the
        // Accessibility API. A zone thinner than the gap is a broken file, not a
        // layout, and leaving it alone says so more usefully than a window at
        // infinity would.
        guard full.width > gap, full.height > gap else { return full }
        return full.insetBy(dx: gap / 2, dy: gap / 2)
    }

    /// Space between two neighbouring windows, in points.
    ///
    /// Each of the two gives up half, so this is the number you actually see
    /// between them — and half of it is what is left against the screen edge,
    /// until `defaults.margin` exists to say otherwise.
    ///
    /// Hardcoded for now, and that is fine; what was not fine was having it
    /// written down in two places that disagreed.
    static let gap: CGFloat = 8
}

/// A set of zones that are used together.
///
/// `Equatable` is not decoration. It is what lets the file watcher ignore a
/// save that changed nothing but the formatting, what lets undo coalesce a run
/// of drags into one step, and what answers "did this actually change?" without
/// comparing rendered text. `Zone` already was; the pair only became meaningful
/// once `id` left the schema, because until then two reads of the very same
/// file compared different.
struct Layout: Codable, Equatable {
    var name: String
    var zones: [Zone]

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

