import Foundation

/// Putting an edited document back into the file it came from.
///
/// This is the piece Rule 2 is about, and the last one the editor needed. It
/// **renders from the tree, never from the `Codable` structs** — Rule 4 — so a
/// key this version of the app has never heard of comes back out exactly as it
/// went in. It is also the only place in the app that writes a layout other
/// than `zonas fmt`, and it makes the same promise that one does: it would
/// rather refuse than hand back a file quietly missing a line somebody typed.
///
/// ### What it does that `fmt` does not
///
/// `fmt` re-renders a tree it did not change. This one changes it first, so it
/// has two jobs `fmt` never had: matching each zone in the document to the node
/// it came from, and knowing which comments are *supposed* to disappear.
enum LayoutWriter {

    /// Something went wrong that must not end in a write.
    struct Refused: Error, CustomStringConvertible {
        let lost: [String]
        var description: String {
            "writing would lose \(lost.count) comment" + (lost.count == 1 ? "" : "s")
        }
    }

    struct NotALayout: Error, CustomStringConvertible {
        var description: String { "the file is not a layout this editor can write into" }
    }

    /// The edited zones, rendered back into the text they came from.
    ///
    /// Everything outside `zones` is left exactly as it was: the preamble, the
    /// version, the defaults, the epilogue, and any key at all that this version
    /// does not recognise.
    static func apply(_ document: EditorDocument, to text: String) throws -> String {
        let original = try LayoutSyntax.parse(text)
        guard case .object(var members) = original.root,
              let listed = members.firstIndex(where: { $0.key == "zones" }),
              case .array(let elements) = members[listed].node
        else { throw NotALayout() }

        // Which of the file's zones are not coming back. Their comments go with
        // them, and that is the one legitimate way a comment leaves this file —
        // see `survivors`.
        let kept = Set(document.zones.map(\.rid).filter { $0 < document.originalCount })
        let removed = elements.indices.filter { !kept.contains($0) }

        members[listed].node = .array(document.zones.map { zone in
            // A zone that came out of the file is *edited*, not rebuilt: the
            // element keeps its own comments, its blank line, and any key in it
            // this app does not know about. Building a fresh one and copying the
            // comments across would look the same until the day somebody's file
            // had a key in it that we dropped on the floor.
            guard zone.rid < document.originalCount, zone.rid < elements.count else {
                return fresh(zone)
            }
            var element = elements[zone.rid]
            element.node = updated(element.node, from: zone)
            return element
        })

        var edited = original
        edited.root = .object(members)
        let rendered = LayoutSyntax.render(edited)

        // Rule 2, with the one exception the editor introduces. `fmt` can insist
        // that every comment survives because it changes nothing; a delete is
        // supposed to take the zone's own notes with it. Anything else going
        // missing is a bug in here, and refusing beats writing it.
        let lost = LayoutSyntax.lost(
            from: survivors(of: original, dropping: removed, in: elements),
            to: LayoutSyntax.comments(of: try LayoutSyntax.parse(rendered)))
        guard lost.isEmpty else { throw Refused(lost: lost) }

        return rendered
    }

    /// Every comment in the file except the ones attached to zones that are
    /// being deleted.
    ///
    /// **This is the honest form of the merge condition for an editor.** A
    /// writer that never loses a comment cannot delete a zone, and a writer that
    /// deletes zones cannot claim `fmt`'s guarantee. The difference between the
    /// two is exactly this list, so it is computed rather than assumed, and
    /// everything not on it still has to survive.
    static func survivors(of document: LayoutSyntax.Document,
                          dropping removed: [Int],
                          in elements: [LayoutSyntax.Element]) -> [String] {
        var doomed: [String] = []
        for index in removed where index < elements.count {
            var stripped = document
            stripped.root = .array([elements[index]])
            stripped.preamble = []
            stripped.epilogue = []
            doomed += LayoutSyntax.comments(of: stripped)
        }
        return LayoutSyntax.lost(from: LayoutSyntax.comments(of: document), to: doomed)
    }

    // MARK: - One zone

    private static func fresh(_ zone: EditZone) -> LayoutSyntax.Element {
        LayoutSyntax.Element(node: .object([
            LayoutSyntax.Member(key: "name", node: .string(zone.name)),
            LayoutSyntax.Member(key: "x", node: node(for: zone.x)),
            LayoutSyntax.Member(key: "y", node: node(for: zone.y)),
            LayoutSyntax.Member(key: "width", node: node(for: zone.width)),
            LayoutSyntax.Member(key: "height", node: node(for: zone.height)),
        ]))
    }

    private static func updated(_ node: LayoutSyntax.Node, from zone: EditZone)
        -> LayoutSyntax.Node {
        guard case .object(var members) = node else { return fresh(zone).node }

        let values: [(String, LayoutSyntax.Node)] = [
            ("name", .string(zone.name)),
            ("x", self.node(for: zone.x)),
            ("y", self.node(for: zone.y)),
            ("width", self.node(for: zone.width)),
            ("height", self.node(for: zone.height)),
        ]
        for (key, value) in values {
            if let index = members.firstIndex(where: { $0.key == key }) {
                // Only the node changes. The member keeps its comments, so
                // `// the work one` written beside a width stays beside it.
                members[index].node = value
            } else {
                members.append(LayoutSyntax.Member(key: key, node: value))
            }
        }
        return .object(members)
    }

    /// How a number goes into the file.
    ///
    /// **A ratio when there is one**, which is the whole reason the editor snaps
    /// to the denominators the format can write. Three columns dragged into
    /// place come out as `"1/3"` and add up to exactly one; the same three
    /// written as `0.3333` leave a sliver on the right edge that is invisible in
    /// the file and maddening on screen. §5 puts it in one line: you snap to the
    /// grid and the file is written as `1/3`, not `0.3333333333333333`.
    ///
    /// Six decimals for everything else, which is what ⌥ produces. One
    /// millionth of a screen is five thousandths of a point on the ultrawide, so
    /// the value that comes back is the value that went in as far as anything
    /// can tell — and seventeen significant figures in a file somebody is meant
    /// to read is noise pretending to be precision.
    static func node(for value: Double) -> LayoutSyntax.Node {
        if let (numerator, denominator) = Fraction.clean(value) {
            if numerator == 0 { return .number("0") }
            if numerator == denominator { return .number("1") }
            return .string("\(numerator)/\(denominator)")
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return .number(text)
    }
}
