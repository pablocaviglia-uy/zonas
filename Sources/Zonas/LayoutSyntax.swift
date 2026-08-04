import Foundation

/// The JSON5 layer: text in, tree out, text back — with the comments intact.
///
/// One parser serves five jobs, which is the reason it exists as a component
/// rather than as a `Codable` conformance: the typed model, the canonical
/// render, the survival of keys this version does not know about, line numbers
/// for schema errors, and the tree that migrations run against.
///
/// ### Why a tree and not text surgery
///
/// The obvious alternative is to splice edited values back into the original
/// text, leaving everything untouched. It loses on one concrete point: the zone
/// table is aligned into columns, that alignment is what makes the file read
/// like a table and makes changing one zone a one-line diff, and **alignment is
/// unsustainable under splicing**. Replace `0.25` with `0.3333` and the columns
/// rot; every edit leaves the file slightly uglier. Splicing also cannot express
/// add, delete or reorder without ad-hoc text surgery, which is a new class of
/// bug per operation.
///
/// The social contract is `gofmt`'s instead: the format is canonical, and it is
/// made canonical **when you ask**, so the one large reformat is a deliberate,
/// reviewable act rather than a surprise.
///
/// ### The rule that governs the writer
///
/// **It renders from the tree, never from the `Codable` structs.** If it
/// serialized the typed model, any key this version of the app does not know
/// about would vanish silently on the first write. The tree keeps it. That is
/// also what makes a migration fifteen lines over a loose tree instead of
/// historical structs living in the source forever.
enum LayoutSyntax {

    // MARK: - The tree

    /// A parsed value, plus whatever is needed to write it back out unharmed.
    ///
    /// Deliberately **not** `Equatable`. "Are these two trees the same?" has no
    /// good answer — same values but different comments? same comments but a
    /// line apart? — and the question anybody actually wants answered is about
    /// the layout, which is `Equatable` and means exactly one thing.
    enum Node {
        case object([Member])
        case array([Element])
        case string(String)
        /// Kept **verbatim**: `0.25` stays `0.25` and `.25` stays `.25`.
        ///
        /// Parsing to `Double` and formatting on the way out would quietly
        /// rewrite what the user typed, and `0.1` does not survive that trip
        /// intact anyway.
        case number(String)
        case bool(Bool)
        case null
    }

    /// One `key: value` inside an object.
    struct Member {
        var key: String
        var node: Node
        var comments = Comments()
        /// The line the key is on.
        ///
        /// It is here so that "zones has to be a list" can say *which* line to
        /// go look at. A schema error without one is barely better than no
        /// error: the whole promise of a config file is that you can fix it.
        var line = 0
    }

    /// One value inside an array.
    struct Element {
        var node: Node
        var comments = Comments()
        /// The line the value starts on. See `Member.line`.
        var line = 0
    }

    /// The comments attached to a node, and the blank line above it.
    ///
    /// What this does **not** preserve, said here rather than discovered later:
    /// blank-line grouping beyond one boolean per node, and comments floating
    /// somewhere there is no node to attach them to — those attach to the node
    /// that follows, by the rule in `trailingComment()`. ASCII diagrams do
    /// survive: the lexer keeps comment text verbatim, byte for byte.
    struct Comments {
        /// Comments sitting on the lines above.
        var leading: [String] = []
        /// A comment on the same line, after the value.
        var trailing: String?
        /// Whether a blank line separated this node from the one before it.
        var blankLineBefore = false
    }

    /// A whole file: the top-level value, and the header above it.
    ///
    /// The preamble gets a slot of its own because there is no node for it to
    /// attach to. Without it, the twenty lines that explain the file to whoever
    /// opens it would be dropped by the first write.
    struct Document {
        var preamble: [String] = []
        var root: Node
        /// Comments after the closing brace, which have nothing to attach to
        /// either.
        ///
        /// This used to be a parse error, on the reasoning that a comment with
        /// no node would be dropped on the next write. That reasoning was right
        /// and the conclusion was wrong: adding a note at the end of a file is
        /// an ordinary thing to do, and throwing out somebody's entire layout
        /// over it is the exact hostility this project is supposed to be against.
        /// A slot costs three lines and keeps the comment.
        var epilogue: [String] = []
        /// The line the top-level value opens on, for the errors that are about
        /// the file as a whole rather than about one key in it.
        var rootLine = 1
    }

    /// A syntax error, with the place it happened.
    ///
    /// The line number is the whole point: "the file does not parse" is not
    /// something you can act on, and the error a plain `JSONDecoder` produces
    /// names a byte offset.
    struct ParseError: Error, CustomStringConvertible, Equatable {
        let line: Int
        let column: Int
        let message: String

        var description: String { "line \(line), column \(column): \(message)" }
    }

    // MARK: - Reading

    static func parse(_ text: String) throws -> Document {
        var parser = Parser(text)
        return try parser.parseDocument()
    }

    /// Every comment in the document, in the order they appear.
    static func comments(of document: Document) -> [String] {
        document.preamble + comments(in: document.root) + document.epilogue
    }

    private static func comments(in node: Node) -> [String] {
        switch node {
        case .object(let members):
            return members.flatMap { comments(of: $0.comments) + comments(in: $0.node) }
        case .array(let elements):
            return elements.flatMap { comments(of: $0.comments) + comments(in: $0.node) }
        default:
            return []
        }
    }

    private static func comments(of comments: Comments) -> [String] {
        comments.leading + (comments.trailing.map { [$0] } ?? [])
    }

    // MARK: - The merge condition

    /// The comments in `before` that are not in `after`, **counting repeats**.
    ///
    /// This is the check the whole canonical-writer design rests on, and it is
    /// five lines because that is all it needs to be. It earns its place by
    /// catching a bug class that idempotency does not: the writer was broken on
    /// purpose once — trailing-comment handling for arrays removed — and
    /// `render(parse(render(x)))` was still stable byte for byte while two of
    /// the user's comments were gone.
    ///
    /// Counting repeats rather than comparing sets is deliberate. The same
    /// comment appears twice in a real file more often than not, and a set
    /// comparison calls it survived when one of the two was dropped.
    static func lost(from before: [String], to after: [String]) -> [String] {
        var available: [String: Int] = [:]
        for comment in after { available[comment, default: 0] += 1 }

        return before.filter { comment in
            guard let left = available[comment], left > 0 else { return true }
            available[comment] = left - 1
            return false
        }
    }

    /// The comments that would not survive writing this document out and
    /// reading it back.
    static func commentsLost(rendering document: Document) throws -> [String] {
        lost(from: comments(of: document), to: comments(of: try parse(render(document))))
    }

    // MARK: - Writing

    /// The canonical rendering.
    static func render(_ document: Document) -> String {
        var out = document.preamble.map { $0 + "\n" }.joined()
        if !document.preamble.isEmpty { out += "\n" }
        write(document.root, into: &out, indent: 0)
        if !out.hasSuffix("\n") { out += "\n" }
        if !document.epilogue.isEmpty {
            out += "\n" + document.epilogue.map { $0 + "\n" }.joined()
        }
        return out
    }

    /// The order keys are written in, when the format has an opinion.
    ///
    /// Everything not listed keeps the order it had in the file — see
    /// `canonicallyOrdered`, which is where that promise is actually kept.
    private static let documentKeyOrder = ["version", "defaults", "layouts", "screens"]
    private static let inlineKeyOrder =
        ["name", "x", "y", "width", "height", "builtin", "minWidth", "minHeight", "layout"]

    /// Sorts by the canonical order, and by original position within a tie.
    ///
    /// The tiebreak is not decoration: **Swift's sort is not stable**, so
    /// without it two keys the format has no opinion about could come out in
    /// either order — which would make the writer non-deterministic exactly for
    /// the unknown keys it is supposed to be protecting, and would break
    /// idempotency at random rather than reproducibly.
    private static func canonicallyOrdered(_ members: [Member], by order: [String]) -> [Member] {
        members.enumerated()
            .sorted { a, b in
                let rankA = order.firstIndex(of: a.element.key) ?? order.count
                let rankB = order.firstIndex(of: b.element.key) ?? order.count
                return rankA == rankB ? a.offset < b.offset : rankA < rankB
            }
            .map(\.element)
    }

    private static func write(_ node: Node, into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)

        switch node {
        case .object(let members):
            out += "{\n"
            for member in canonicallyOrdered(members, by: documentKeyOrder) {
                if member.comments.blankLineBefore { out += "\n" }
                for comment in member.comments.leading { out += pad + "  " + comment + "\n" }
                out += pad + "  " + member.key + ": "
                write(member.node, into: &out, indent: indent + 1)
                out += ","
                if let trailing = member.comments.trailing { out += "  " + trailing }
                out += "\n"
            }
            out += pad + "}"

        case .array(let elements):
            let columns = columnWidths(for: elements)
            out += "[\n"
            for element in elements {
                if element.comments.blankLineBefore { out += "\n" }
                for comment in element.comments.leading { out += pad + "  " + comment + "\n" }
                out += pad + "  "
                if let columns {
                    out += inlined(element.node, columns: columns)
                } else {
                    write(element.node, into: &out, indent: indent + 1)
                }
                out += ","
                if let trailing = element.comments.trailing { out += "  " + trailing }
                out += "\n"
            }
            out += pad + "]"

        default:
            out += scalar(node)
        }
    }

    /// The per-key widths that turn an array of zones into an aligned table, or
    /// `nil` when this array is not that kind of array.
    ///
    /// The alignment is the reason the format is worth having: it is what makes
    /// the geometry visible at a glance and what makes changing one zone a
    /// one-line diff. It only applies to short, flat, homogeneous objects —
    /// anything else renders block style, because padding a heterogeneous list
    /// produces columns that line up with nothing.
    private static func columnWidths(for elements: [Element]) -> [String: Int]? {
        guard !elements.isEmpty else { return nil }

        var keySets: Set<[String]> = []
        var widths: [String: Int] = [:]

        for element in elements {
            guard case .object(let members) = element.node,
                  members.count <= 6,
                  members.allSatisfy({ isScalar($0.node) }) else { return nil }
            keySets.insert(members.map(\.key).sorted())
            for member in members {
                widths[member.key] = max(widths[member.key] ?? 0, scalar(member.node).count)
            }
        }
        // Heterogeneous rows have no columns to align.
        guard keySets.count == 1 else { return nil }
        return widths
    }

    private static func isScalar(_ node: Node) -> Bool {
        switch node {
        case .object, .array: return false
        default: return true
        }
    }

    private static func inlined(_ node: Node, columns: [String: Int]) -> String {
        guard case .object(let members) = node else { return scalar(node) }
        let ordered = canonicallyOrdered(members, by: inlineKeyOrder)

        let parts = ordered.enumerated().map { index, member -> String in
            let value = scalar(member.node)
            let isLast = index == ordered.count - 1
            let padding = isLast ? 0 : max(0, (columns[member.key] ?? value.count) - value.count)
            return "\(member.key): \(value)\(isLast ? "" : ",")\(String(repeating: " ", count: padding))"
        }
        return "{ " + parts.joined(separator: " ") + " }"
    }

    private static func scalar(_ node: Node) -> String {
        switch node {
        case .string(let contents): return quoted(contents)
        case .number(let literal): return literal
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object, .array: return ""
        }
    }

    /// Puts a string back between double quotes.
    ///
    /// The parser keeps escape sequences verbatim, so most content goes straight
    /// back out. The case that does not is a bare `"`, which is perfectly legal
    /// inside the single quotes JSON5 allows —`'say "hi"'`— and would end the
    /// string early here.
    private static func quoted(_ contents: String) -> String {
        var out = "\""
        var afterBackslash = false
        for character in contents {
            if afterBackslash {
                out.append(character)
                afterBackslash = false
            } else if character == "\\" {
                out.append(character)
                afterBackslash = true
            } else {
                if character == "\"" { out.append("\\") }
                out.append(character)
            }
        }
        return out + "\""
    }
}
