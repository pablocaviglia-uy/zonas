import Foundation

/// Moving the window you are working in from the keyboard: the keys, and the
/// rule that decides where each one sends it.
///
/// Everything in here is arithmetic over rectangles. The part that talks to the
/// system — registering the keys and moving the window — is `ShortcutController`,
/// which cannot be unit-tested, so anything with a decision in it is kept on this
/// side of the line.
///
/// **The one property every rule here has to keep is that the answer is a
/// function of the window's position and nothing else.** Rectangle's arrow keys
/// cycle — press ⌃⌥← once for the left half, again for the left third, again for
/// two thirds — so the same key from the same place does three different things
/// depending on what you pressed before, and that was asked for by name as the
/// thing not to build. Nothing in this file remembers a keypress.
enum Direction: String, CaseIterable {
    case left, right, up, down

    /// How it reads in the log and the menu.
    var symbol: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }
}

/// The keys held down with an arrow to move the front window.
///
/// Two or more of the four modifiers, because one on its own with an arrow is
/// already something else's: ⌥→ is a word in every text field, ⌘→ the end of
/// the line, ⇧→ a selection, ⌃→ the next Space. A global hot key takes the
/// combination away from every application at once, so a file that named one
/// key would break word movement everywhere — which is not a thing a config
/// file should be able to do by accident.
struct Chord: Equatable {
    var keys: Set<Modifier>

    /// What the file gets when it says nothing: ⌃⌥, which is what Rectangle,
    /// Magnet and Spectacle all use, so it is what anybody coming from one of
    /// them already has in their fingers. It is also what macOS itself leaves
    /// alone — its own tiling lives on 🌐⌃.
    static let standard = Chord(keys: [.control, .option])

    /// How it reads in a menu: `⌃⌥`, in the order the keyboard prints them.
    var symbol: String {
        Modifier.allCases.filter(keys.contains).map(\.symbol).joined()
    }

    /// Reads `"control+option"`. The names are the same four the file uses for
    /// `modifier` and `span`, joined with `+`; spaces around them are tolerated
    /// because somebody will type them.
    init?(_ text: String) {
        let names = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var keys: Set<Modifier> = []
        for name in names {
            guard let key = Modifier(rawValue: name) else { return nil }
            keys.insert(key)
        }
        self.keys = keys
    }

    init(keys: Set<Modifier>) {
        self.keys = keys
    }
}

extension Layout {

    /// The zone one press of an arrow sends a window to, or `nil` when there is
    /// nothing that way.
    ///
    /// `frame` is where the window is now, `area` the usable area of the screen
    /// it is on, and the answer is an index into `zones` — the same handle the
    /// drag uses, for the same reason: it is the only one that is still right
    /// when two zones are identical.
    ///
    /// **A zone is "to the right" when all of it is past the middle of the
    /// window.** Not past the window's edge, which would refuse a floating
    /// window that overlaps the zone beside it by a few points — that is most
    /// floating windows — and not past the window's *centre* compared with the
    /// zone's centre, which makes a full-height column count as "below" a
    /// quarter-height zone in the top corner. The rule as written excludes the
    /// zone the window is sitting in, because its near edge is on the wrong
    /// side of the middle, and that is what keeps → from ever re-snapping a
    /// window into the zone it already occupies.
    ///
    /// **Among those, the ones across from the window: a line from the
    /// window's middle runs into the zone, or the window is tall enough to
    /// cover all of a window in that zone** — wide enough, for ↑ and ↓. The
    /// first half is what a person means by "the zone to my right", and it is
    /// the drag's own question asked with the middle of the window instead of
    /// the pointer. The second half is for a window in a full-height column
    /// beside two stacked zones, where the line from its middle runs into only
    /// one of them.
    ///
    /// Two earlier versions of "across" lost, one to a test and one to a desk.
    /// "Any zone sharing some of the window's height" sent a window sitting in
    /// the middle column and hanging 280 points into the left one to the
    /// bottom-left zone on ↓, because the zone under that sliver counted as
    /// below; nobody looking at that window would have called it that. "The
    /// line from the middle" alone then sent → from the top-left corner through
    /// the middle column and out at the *bottom*-right — on the layout this was
    /// written against the right-hand pair is split at 0.4765, so the middle of
    /// the column is in the lower zone — and the person pressing it expected to
    /// stay in the top row. A column that tall is beside both zones, and the
    /// rule now says so; which of the two it picks is the tie-break's job.
    ///
    /// The cover test is against the zone's *frame*, gap and margin included,
    /// not its hit region. A window snapped into a column with `margin: 20` is
    /// twenty points shorter than the column's hit region and would cover
    /// nothing; it is exactly as tall as the frames, which is what "covers a
    /// window in that zone" means.
    ///
    /// **Then the nearest, then the topmost — the leftmost, for ↑ and ↓ — and
    /// only then file order.** Nearest so that a strip beside the window is not
    /// skipped for a wider zone behind it. Topmost because that is reading
    /// order, and because it is the one promise a rule with no memory can
    /// keep: from a full-height column, → is the top of the next column
    /// whichever row you came from. File order decides only between zones with
    /// the same geometry, which a file may perfectly well contain.
    ///
    /// Nothing across from the window means nothing to move to, and the key
    /// does nothing. A diagonal fallback was considered and left out: a window
    /// that goes somewhere you did not point it is a bug report, a key that
    /// does nothing is a line in the log.
    func neighbour(of frame: CGRect, towards direction: Direction, in area: CGRect) -> Int? {
        let rects = zones.map { $0.rect(in: area) }
        let frames = zones.map { self.frame(of: $0, in: area) }
        let horizontal = direction == .left || direction == .right

        // How far the window's far edge is from the zone's near edge, and where
        // the zone starts along the other axis — or `nil` for a zone that is
        // not beside the window at all. The comparisons are closed on both
        // ends on purpose: a middle exactly on the line between two zones is
        // across from both, and the tie-break decides.
        func measure(_ index: Int) -> (gap: CGFloat, lead: CGFloat)? {
            let rect = rects[index]
            let own = frames[index]
            let across: Bool
            if horizontal {
                let inLine = rect.minY <= frame.midY && frame.midY <= rect.maxY
                let covered = own.minY >= frame.minY && own.maxY <= frame.maxY
                across = inLine || covered
            } else {
                let inLine = rect.minX <= frame.midX && frame.midX <= rect.maxX
                let covered = own.minX >= frame.minX && own.maxX <= frame.maxX
                across = inLine || covered
            }
            guard across else { return nil }

            let gap: CGFloat
            switch direction {
            case .right:
                guard rect.minX >= frame.midX else { return nil }
                gap = rect.minX - frame.maxX
            case .left:
                guard rect.maxX <= frame.midX else { return nil }
                gap = frame.minX - rect.maxX
            case .down:
                guard rect.minY >= frame.midY else { return nil }
                gap = rect.minY - frame.maxY
            case .up:
                guard rect.maxY <= frame.midY else { return nil }
                gap = frame.minY - rect.maxY
            }
            // A window already overlapping the zone is at distance zero, not at
            // a negative one that would sort it ahead of a zone flush against it.
            return (max(gap, 0), horizontal ? rect.minY : rect.minX)
        }

        // A loop and not `min(by:)` over tuples, which the type-checker gave
        // up on. It replaces the best so far only for a zone that is strictly
        // nearer, or as near and higher up, so of two zones with the same
        // geometry it keeps the earlier — file order, because `indices` is.
        var best: (index: Int, gap: CGFloat, lead: CGFloat)?
        for index in rects.indices {
            guard let found = measure(index) else { continue }
            guard let current = best else {
                best = (index, found.gap, found.lead)
                continue
            }
            let nearer = found.gap < current.gap
            let higher = found.gap == current.gap && found.lead < current.lead
            if nearer || higher { best = (index, found.gap, found.lead) }
        }
        return best?.index
    }

    /// The zone a window is in: the smallest one under its centre, which is the
    /// drag's own rule with the pointer replaced by the middle of the window.
    ///
    /// It is the centre and not the largest overlap because the centre is what
    /// a person points at when they say "that window is in the middle column",
    /// and because a window bigger than every zone would otherwise be "in"
    /// whichever zone happens to be widest.
    func zoneIndex(holding frame: CGRect, in area: CGRect) -> Int? {
        zoneIndex(under: CGPoint(x: frame.midX, y: frame.midY), in: area)
    }
}
