import Foundation

/// A zone while it is being edited.
///
/// The difference from `Zone` is `rid`, and `rid` is the whole reason this type
/// exists. §5: identity is stable **in memory**, not in the file. It is minted
/// when the editor opens, it drives selection and undo, and it never reaches
/// disk — the file's handle is `name`, unique within its layout.
///
/// That works because the file is not the authority on identity *during* an
/// editing session; the document is. Between sessions there is nothing to track,
/// because nobody needs undo across a relaunch. This is the same reasoning that
/// took `id` out of the schema in §3a, arriving at the opposite answer for the
/// opposite lifetime.
struct EditZone: Equatable {
    let rid: Int
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// The orientation of the line you cut along.
///
/// Named after the line and not after the result, because both namings are
/// ambiguous and this one at least matches what is drawn: `.vertical` is a
/// vertical line, so it leaves one piece beside the other.
enum Cut: Equatable {
    case vertical
    case horizontal

    /// Perpendicular to the longest side, which is what makes the ultrawide
    /// template five clicks with no modifier: a full-width zone cuts vertically,
    /// and as soon as the columns are taller than they are wide the default
    /// turns itself round.
    static func `default`(for rect: CGRect) -> Cut {
        rect.width >= rect.height ? .vertical : .horizontal
    }

    var rotated: Cut { self == .vertical ? .horizontal : .vertical }
}

/// A line in the layout that can be grabbed and moved.
///
/// **There is no tree.** Splitting suggests one, and a tree does not fit in a
/// file that is a flat list of rectangles — putting it there would make the file
/// nested and horrible to hand-write, and reconstructing it on load is ambiguous
/// and fragile. §5's answer is this: an edge is *derived*, worked out from the
/// zones whenever it is needed and never stored. Two zones that share a boundary
/// share it because their numbers say so, not because something remembers that
/// they were once one zone.
///
/// The consequence that makes it worth it: because the zones on both sides are
/// moved by one number, **the one-pixel gap becomes impossible by
/// construction**. It cannot be introduced by dragging, only written on purpose.
struct EditorEdge: Equatable {
    /// Which way the line runs. `.vertical` is a vertical line, so it lives at
    /// an *x* coordinate.
    let axis: Cut
    /// Where it sits, as a fraction of the screen's usable area.
    let coordinate: Double
    /// Zones whose **leading** side is on the line — `x`, or `y`. Moving the
    /// line moves their origin and changes their size the other way.
    let leading: [Int]
    /// Zones whose **trailing** side is on it — `x + width`, or `y + height`.
    /// Moving the line only changes their size.
    let trailing: [Int]
    /// How far the line runs along itself, for drawing it.
    let from: Double
    let to: Double

    var isAlone: Bool { leading.count + trailing.count == 1 }
    var zoneCount: Int { leading.count + trailing.count }
}

/// The layout the editor is working on, in memory.
///
/// **It is not the file and it does not write one.** Splitting, and everything
/// after it up to the last stretch of this editor, changes this and nothing
/// else; closing the editor throws it away. That ordering is Rule 1 read
/// strictly — the editor may be built against the syntax, but it becomes a
/// *writer* last, when there is something worth writing and the conflict
/// question has an answer.
///
/// One document for every screen, not one per screen. There is a single layout
/// today, drawn at 1:1 against each screen's own usable area, so a split made on
/// the laptop has to appear on the ultrawide at the same instant — and it does,
/// because both windows draw this.
struct EditorDocument: Equatable {

    private(set) var zones: [EditZone]

    /// Carried through untouched so that the document can hand back a `Layout`
    /// that snaps and draws identically. None of them are editable here; the
    /// file is still where you change a gap.
    let name: String
    let gap: CGFloat
    let margin: CGFloat
    let modifier: Modifier

    private var nextRid: Int
    private var history: [[EditZone]] = []

    /// Whether anything has been changed since the document was built.
    ///
    /// It is what decides whether an external save is allowed to replace this
    /// document — see `EditorController.refresh`.
    var isEdited: Bool { !history.isEmpty }

    init(_ layout: Layout) {
        zones = layout.zones.enumerated().map { index, zone in
            EditZone(rid: index, name: zone.name,
                     x: zone.x, y: zone.y, width: zone.width, height: zone.height)
        }
        nextRid = zones.count
        name = layout.name
        gap = layout.gap
        margin = layout.margin
        modifier = layout.modifier
    }

    /// The same zones as something that draws and snaps.
    ///
    /// Going back through `Layout` rather than teaching the editor to draw
    /// `EditZone` directly is deliberate: `Layout.viewFrames(in:)` is the one
    /// expression that decides where a window lands, so routing the editor
    /// through it is what keeps "what you see" and "what you would get" the same
    /// sentence rather than two implementations of one.
    var layout: Layout {
        Layout(name: name,
               zones: zones.map { Zone(name: $0.name, x: $0.x, y: $0.y,
                                       width: $0.width, height: $0.height) },
               gap: gap, margin: margin, modifier: modifier)
    }

    func index(of rid: Int) -> Int? { zones.firstIndex { $0.rid == rid } }

    // MARK: - Splitting

    /// Cuts one zone in two.
    ///
    /// `fraction` is in the same units the zones are — a fraction of the
    /// screen's usable area along the axis being cut — so this arithmetic knows
    /// nothing about points, screens, or which monitor you clicked on.
    ///
    /// `minimum` is the caller's, for the same reason and in the same units. A
    /// sensible smallest zone is a number of points, points differ per screen,
    /// and one layout is drawn on all of them — so the only screen whose opinion
    /// can be honoured is the one you are looking at, and the view is the only
    /// thing that knows which that is.
    ///
    /// Returns whether anything happened, so a click too close to an edge is a
    /// click that does nothing rather than a zone of no width.
    @discardableResult
    mutating func split(rid: Int, at fraction: Double, _ cut: Cut, minimum: Double) -> Bool {
        guard let index = index(of: rid) else { return false }
        let zone = zones[index]

        let start = cut == .vertical ? zone.x : zone.y
        let extent = cut == .vertical ? zone.width : zone.height
        let first = fraction - start
        let second = start + extent - fraction
        guard first >= minimum, second >= minimum else { return false }

        history.append(zones)

        // The first piece keeps the name. "Under the cursor" would be the
        // friendlier rule and it is not a rule at all: at the moment of the
        // click the cursor is *on* the line, so it is in neither piece. Left
        // and top are where a reader starts.
        var head = zone
        var tail = zone
        tail.name = uniqueName(basedOn: zone.name)

        switch cut {
        case .vertical:
            head.width = first
            tail.x = fraction
            tail.width = second
        case .horizontal:
            head.height = first
            tail.y = fraction
            tail.height = second
        }

        zones[index] = head
        zones.insert(EditZone(rid: nextRid, name: tail.name, x: tail.x, y: tail.y,
                              width: tail.width, height: tail.height),
                     at: index + 1)
        nextRid += 1
        return true
    }

    /// A name nobody else in this layout has.
    ///
    /// `name` is the file's handle and has to stay unique, and it is also the
    /// thing drawn across the middle of the zone — two zones called "Left" were
    /// already a bug before anything could write them.
    ///
    /// The trailing number is stripped before counting, so splitting "Centro 2"
    /// gives "Centro 3" and not "Centro 2 2". Three splits deep, the second
    /// spelling is unreadable and it is the spelling you get by default.
    private func uniqueName(basedOn name: String) -> String {
        let taken = Set(zones.map(\.name))
        let stem = Self.stem(of: name)
        var n = 2
        while taken.contains("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }

    private static func stem(of name: String) -> String {
        guard let space = name.lastIndex(of: " ") else { return name }
        let tail = name[name.index(after: space)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return name }
        return String(name[..<space])
    }

    // MARK: - Edges

    /// How far off two edges may be and still count as the same line: §5's
    /// half a percent of the screen.
    ///
    /// The number is a fraction and not a number of points on purpose. One
    /// layout is drawn on every screen, so a tolerance in points would coalesce
    /// on the laptop and not on the ultrawide, and the same drag would produce
    /// two different files depending on which monitor you happened to use.
    ///
    /// What it is for: a hand-written file that says `0.3333` on one side of a
    /// boundary and `1/3` on the other has a hairline crack in it, and dragging
    /// that boundary should close the crack rather than carry it along.
    static let coalescence = 0.005

    /// The outermost hundredth of the screen is not a divider, it is the screen.
    /// Dragging it would only pull the layout away from the edge, which is what
    /// `margin` is for, and it would do it by accident every time somebody
    /// aimed at the first zone.
    private static let screenBoundary = 0.001

    private struct Side {
        let rid: Int
        let coordinate: Double
        let leading: Bool
        let from: Double
        let to: Double
    }

    private func sides(along axis: Cut) -> [Side] {
        zones.flatMap { zone -> [Side] in
            let start = axis == .vertical ? zone.x : zone.y
            let extent = axis == .vertical ? zone.width : zone.height
            let from = axis == .vertical ? zone.y : zone.x
            let to = from + (axis == .vertical ? zone.height : zone.width)
            return [Side(rid: zone.rid, coordinate: start, leading: true, from: from, to: to),
                    Side(rid: zone.rid, coordinate: start + extent, leading: false, from: from, to: to)]
        }
    }

    /// The line you would be grabbing at this point, with everything collinear
    /// gathered into it.
    ///
    /// - Parameters:
    ///   - coordinate: where the cursor is across the line.
    ///   - across: where the cursor is *along* it. This is what tells one
    ///     segment from another when a coordinate carries several — a vertical
    ///     line broken in the middle by a full-width zone is two dividers, and
    ///     moving one must not move the other.
    ///   - reach: how far the cursor may be from a line and still be grabbing
    ///     it. **Not the same number as `tolerance`, and confusing the two is
    ///     the bug this signature exists to prevent**: reach is about aim and is
    ///     tens of points, tolerance is about what counts as one line and is a
    ///     rounding error. On the ultrawide a comfortable reach is already wider
    ///     than the coalescence tolerance, so a single number would either make
    ///     dividers unclickable or glue unrelated ones together.
    ///
    /// The group grows from the side under the cursor by extents that overlap
    /// **or touch**, transitively. Touching matters: four zones stacked two and
    /// two meet at a point, share no interior at all, and are plainly one line
    /// to anybody looking at the screen.
    func edge(along axis: Cut, near coordinate: Double, across: Double,
              within reach: Double,
              tolerance: Double = EditorDocument.coalescence) -> EditorEdge? {
        let all = sides(along: axis).filter {
            $0.coordinate > Self.screenBoundary && $0.coordinate < 1 - Self.screenBoundary
        }
        guard let seed = all
            .filter({ $0.from <= across && across <= $0.to
                      && abs($0.coordinate - coordinate) <= reach })
            .min(by: { abs($0.coordinate - coordinate) < abs($1.coordinate - coordinate) })
        else { return nil }

        // Gathered around the **seed**, not around the cursor: the line you are
        // holding is the one you pointed at, and what comes with it is measured
        // from there.
        let candidates = all.filter { abs($0.coordinate - seed.coordinate) <= tolerance }

        var group = [seed]
        var grew = true
        while grew {
            grew = false
            for side in candidates
            where !group.contains(where: { $0.rid == side.rid && $0.leading == side.leading }) {
                guard group.contains(where: { max($0.from, side.from) <= min($0.to, side.to) })
                else { continue }
                group.append(side)
                grew = true
            }
        }
        return Self.gather(group, axis: axis, at: seed.coordinate)
    }

    /// One zone's own side, for when ⌥ has broken the coalescence.
    ///
    /// This is how a gap or an overlap is made **on purpose**, which the editor
    /// has to be able to do or it would be less expressive than the file — and
    /// `zone(under:in:)` implements smallest-wins precisely so that overlapping
    /// zones work.
    func side(of rid: Int, along axis: Cut, nearest coordinate: Double) -> EditorEdge? {
        let mine = sides(along: axis).filter { $0.rid == rid }
        guard let closest = mine
            .min(by: { abs($0.coordinate - coordinate) < abs($1.coordinate - coordinate) })
        else { return nil }
        return Self.gather([closest], axis: axis, at: closest.coordinate)
    }

    private static func gather(_ group: [Side], axis: Cut, at coordinate: Double) -> EditorEdge {
        EditorEdge(axis: axis,
                   // The seed's coordinate, not the average of the group: it is
                   // the line you pointed at, and moving it somewhere you did
                   // not point before you have dragged anything would be the
                   // editor taking the first step for you.
                   coordinate: coordinate,
                   leading: group.filter(\.leading).map(\.rid),
                   trailing: group.filter { !$0.leading }.map(\.rid),
                   from: group.map(\.from).min() ?? 0,
                   to: group.map(\.to).max() ?? 1)
    }

    /// Moves a line, and everything that was on it, to a new coordinate.
    ///
    /// Clamped so that nothing on either side ends up under `minimum`. Clamping
    /// is right here and refusing was right for the split, and the difference is
    /// that a drag is continuous: you are already holding the line, and having
    /// it stop against a limit is how a limit should feel. A split is one
    /// discrete act, and moving it somewhere you did not click would be the
    /// editor answering a different question.
    ///
    /// One undo step per call, so the gesture has to call it **once, on the way
    /// up** — the preview during the drag runs against a copy.
    @discardableResult
    mutating func move(_ edge: EditorEdge, to target: Double, minimum: Double) -> Bool {
        var lowest = 0.0
        var highest = 1.0
        for rid in edge.trailing {
            guard let zone = zones.first(where: { $0.rid == rid }) else { continue }
            lowest = max(lowest, (edge.axis == .vertical ? zone.x : zone.y) + minimum)
        }
        for rid in edge.leading {
            guard let zone = zones.first(where: { $0.rid == rid }) else { continue }
            let far = edge.axis == .vertical ? zone.x + zone.width : zone.y + zone.height
            highest = min(highest, far - minimum)
        }
        guard lowest <= highest else { return false }
        let coordinate = min(max(target, lowest), highest)

        var moved = zones
        for index in moved.indices {
            let rid = moved[index].rid
            if edge.leading.contains(rid) {
                // The origin moves and the far side stays where it was, so the
                // size takes the difference.
                if edge.axis == .vertical {
                    moved[index].width = moved[index].x + moved[index].width - coordinate
                    moved[index].x = coordinate
                } else {
                    moved[index].height = moved[index].y + moved[index].height - coordinate
                    moved[index].y = coordinate
                }
            }
            if edge.trailing.contains(rid) {
                if edge.axis == .vertical {
                    moved[index].width = coordinate - moved[index].x
                } else {
                    moved[index].height = coordinate - moved[index].y
                }
            }
        }

        // A drag that ends where it started is not an undo step. Without this,
        // grabbing a divider and letting go costs you a ⌘Z that undoes nothing.
        guard moved != zones else { return false }
        history.append(zones)
        zones = moved
        return true
    }

    // MARK: - Snapping

    /// Where a coordinate wants to land.
    ///
    /// §5's order, and each tier is answering a different question. **Other
    /// zones' edges first**, because lining up with something already on the
    /// screen is the thing you are almost always trying to do and no fraction
    /// can substitute for it — a zone that lines up with its neighbour above is
    /// right whether or not the number is pretty. **Then the rational lines**,
    /// which is where `1/3` comes from instead of `0.3333333333333333`. **Then
    /// the screen's own edges**, last because they are 320 points from the
    /// nearest sixteenth and the ordering never actually comes up; it is written
    /// down so that the day it does, it does the same thing twice.
    ///
    /// `ignoring` is the zones being moved. Their own edges are the ones
    /// travelling, and a line that snapped to where it already was would be
    /// impossible to move at all.
    ///
    /// `range` is where the answer is allowed to be. Without it the grid can
    /// pull a cut into the band where it would be refused, and the result is a
    /// stripe of screen where hovering shows nothing and no reason is given.
    func snap(_ coordinate: Double, along axis: Cut, ignoring rids: Set<Int>,
              within radius: Double, to range: ClosedRange<Double> = 0...1) -> Double {
        guard radius > 0 else { return coordinate }

        let neighbours = sides(along: axis)
            .filter { !rids.contains($0.rid) }
            .map(\.coordinate)

        for tier in [neighbours, Fraction.lines, [0, 1]] {
            let hit = tier
                .filter { range.contains($0) && abs($0 - coordinate) <= radius }
                .min { abs($0 - coordinate) < abs($1 - coordinate) }
            if let hit { return hit }
        }
        return coordinate
    }

    // MARK: - Deleting

    /// Removes a zone and hands its area to a neighbour.
    ///
    /// §5 says "the neighbour sharing the longest edge", and **that rule on its
    /// own does not work**, which writing the test found. Lengths here are
    /// fractions, so it compares a fraction of the screen's height against a
    /// fraction of its width — two numbers that are only comparable once you
    /// know the aspect ratio. Supplying one does not rescue it either: deleting
    /// the top-left zone of this desk's layout gives 1280 points of shared edge
    /// against 720 on the ultrawide, and 432 against 542 on the laptop. The same
    /// delete would absorb into a different neighbour depending on which monitor
    /// you happened to be looking at, for one layout that is drawn on both.
    ///
    /// So the first question is not how long the shared edge is but **whether
    /// the neighbour lines up with the victim along it**. One that does can take
    /// the area exactly: no hole, no overlap, and it is the zone a person would
    /// point at — the one in the same column or the same row. That test is a
    /// comparison of like with like, so it gives the same answer on every
    /// screen. Longest shared edge is kept as the tie-break, and the file's own
    /// order breaks the tie after that, so the result is always reproducible.
    ///
    /// It can still leave a hole, when no neighbour lines up. That is allowed
    /// rather than prevented, because zones are not required to tile and a hole
    /// is visible the instant it appears — dimmed desktop with no outline — and
    /// you close it by dragging. Refusing the delete instead would let the
    /// editor into states it could not get out of.
    @discardableResult
    mutating func delete(rid: Int) -> Bool {
        // The last zone is not deletable. An empty layout is a layout where the
        // modifier does nothing, with no way back except the file.
        guard zones.count > 1, let index = index(of: rid) else { return false }
        let victim = zones[index]

        var best: (index: Int, alignsExactly: Bool, shared: Double)?
        for (other, zone) in zones.enumerated() where other != index {
            guard let edge = Self.boundary(between: victim, and: zone) else { continue }
            let better = best.map {
                (edge.alignsExactly && !$0.alignsExactly)
                    || (edge.alignsExactly == $0.alignsExactly && edge.shared > $0.shared)
            } ?? true
            if better { best = (other, edge.alignsExactly, edge.shared) }
        }

        history.append(zones)
        if let best {
            zones[best.index] = Self.absorb(victim, into: zones[best.index])
        }
        zones.remove(at: index)
        return true
    }

    /// The boundary two zones share: how much of it there is, and whether the
    /// other zone lines up with this one along it exactly.
    private static func boundary(between victim: EditZone, and other: EditZone)
        -> (shared: Double, alignsExactly: Bool)? {
        let close = Fraction.tolerance

        // Meeting on a vertical line: they share an x, and the boundary runs in y.
        if abs(victim.x + victim.width - other.x) < close
            || abs(other.x + other.width - victim.x) < close {
            let overlap = min(victim.y + victim.height, other.y + other.height)
                - max(victim.y, other.y)
            if overlap > close {
                return (overlap, abs(other.y - victim.y) < close
                                 && abs(other.height - victim.height) < close)
            }
        }
        // Meeting on a horizontal line: they share a y, and it runs in x.
        if abs(victim.y + victim.height - other.y) < close
            || abs(other.y + other.height - victim.y) < close {
            let overlap = min(victim.x + victim.width, other.x + other.width)
                - max(victim.x, other.x)
            if overlap > close {
                return (overlap, abs(other.x - victim.x) < close
                                 && abs(other.width - victim.width) < close)
            }
        }
        return nil
    }

    /// Grows `heir` over `victim`, but only along the axis they meet on.
    ///
    /// Growing both ways would be the greedier answer and it is wrong: it would
    /// swallow whatever else was beside the victim, so deleting one zone would
    /// silently cover two.
    private static func absorb(_ victim: EditZone, into heir: EditZone) -> EditZone {
        var heir = heir
        if abs(heir.x + heir.width - victim.x) < Fraction.tolerance {
            heir.width += victim.width                       // victim is to its right
        } else if abs(victim.x + victim.width - heir.x) < Fraction.tolerance {
            heir.x = victim.x                                // victim is to its left
            heir.width += victim.width
        } else if abs(heir.y + heir.height - victim.y) < Fraction.tolerance {
            heir.height += victim.height                     // victim is below it
        } else if abs(victim.y + victim.height - heir.y) < Fraction.tolerance {
            heir.y = victim.y                                // victim is above it
            heir.height += victim.height
        }
        return heir
    }

    // MARK: - Undo

    /// Undo is a stack of whole-document snapshots.
    ///
    /// A layout is a few dozen small structs, so a snapshot costs nothing to
    /// take and nothing to hold, and an undo that restores a whole document
    /// cannot be wrong the way an undo that reverses an operation can — there is
    /// no inverse to get subtly incorrect. It earns that simplicity now, while
    /// the operations are few; if it ever stops being obviously correct the
    /// reason will be that the document grew, not that this was too clever.
    var canUndo: Bool { !history.isEmpty }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        zones = previous
        return true
    }

    /// Two documents are the same when they hold the same zones and the same
    /// settings.
    ///
    /// `nextRid` and the undo stack are how a document *got here*, not what it
    /// is. The synthesized conformance compares them, and under it "undo puts
    /// the document back" is false — a document you split and undid differs from
    /// the one you started with by the integer the next split would use, which
    /// nothing can observe. The test that caught this is right and the default
    /// was wrong.
    static func == (a: Self, b: Self) -> Bool {
        a.zones == b.zones && a.name == b.name
            && a.gap == b.gap && a.margin == b.margin && a.modifier == b.modifier
    }
}
