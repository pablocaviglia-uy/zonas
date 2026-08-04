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
