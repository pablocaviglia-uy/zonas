import Foundation

// A JSON5 "CST-lite": an ordered tree where every node carries the comments
// attached to it. One parser serves five jobs: typed model, canonical writer,
// unknown-key survival, line numbers for schema errors, and tree migrations.

enum Node {
    case object([(key: String, node: Node, lead: [String], trail: String?, blankBefore: Bool)])
    case array([(node: Node, lead: [String], trail: String?, blankBefore: Bool)])
    case string(String)
    case number(String)      // kept verbatim: 0.25 stays 0.25, .25 stays .25
    case bool(Bool)
    case null
}

struct ParseError: Error { let line: Int; let column: Int; let message: String }

struct Parser {
    let src: [UInt8]
    var i = 0
    var line = 1, col = 1
    var pendingComments: [String] = []
    var sawBlank = false
    var lineOfIndex: [Int: Int] = [:]

    init(_ text: String) { src = Array(text.utf8) }

    mutating func fail(_ m: String) -> ParseError { ParseError(line: line, column: col, message: m) }

    mutating func advance() {
        if src[i] == 0x0A { line += 1; col = 1 } else { col += 1 }
        i += 1
    }
    var atEnd: Bool { i >= src.count }
    func peek(_ o: Int = 0) -> UInt8? { i + o < src.count ? src[i + o] : nil }

    /// Eats whitespace and comments, collecting the comments verbatim.
    mutating func trivia() {
        var newlinesSinceComment = 0
        while !atEnd {
            let c = src[i]
            if c == 0x20 || c == 0x09 || c == 0x0D { advance() }
            else if c == 0x0A { newlinesSinceComment += 1; if newlinesSinceComment > 1 { sawBlank = true }; advance() }
            else if c == 0x2F, peek(1) == 0x2F {
                let start = i
                while !atEnd, src[i] != 0x0A { advance() }
                pendingComments.append(text(start, i))
                newlinesSinceComment = 0
            } else if c == 0x2F, peek(1) == 0x2A {
                let start = i
                advance(); advance()
                while !atEnd, !(src[i] == 0x2A && peek(1) == 0x2F) { advance() }
                if !atEnd { advance(); advance() }
                pendingComments.append(text(start, i))
                newlinesSinceComment = 0
            } else { break }
        }
    }

    func text(_ a: Int, _ b: Int) -> String { String(decoding: src[a..<b], as: UTF8.self) }

    mutating func takeComments() -> ([String], Bool) {
        let c = pendingComments; let b = sawBlank
        pendingComments = []; sawBlank = false
        return (c, b)
    }

    /// A comment sitting on the same line as the value just parsed is a trailing
    /// comment; anything after a newline belongs to the next node.
    mutating func trailingComment() -> String? {
        var j = i
        while j < src.count, src[j] == 0x20 || src[j] == 0x09 { j += 1 }
        guard j + 1 < src.count, src[j] == 0x2F, src[j + 1] == 0x2F else { return nil }
        while i < j { advance() }
        let start = i
        while !atEnd, src[i] != 0x0A { advance() }
        return text(start, i)
    }

    var preamble: [String] = []
    mutating func parseDocument() throws -> Node {
        trivia()
        (preamble, _) = takeComments()
        let n = try parseValue()
        trivia()
        guard atEnd else { throw fail("trailing content after the top-level value") }
        return n
    }

    mutating func parseValue() throws -> Node {
        trivia()
        guard !atEnd else { throw fail("unexpected end of file") }
        switch src[i] {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22, 0x27: return .string(try parseString())
        default:
            if matchWord("true") { return .bool(true) }
            if matchWord("false") { return .bool(false) }
            if matchWord("null") { return .null }
            return .number(try parseNumber())
        }
    }

    mutating func matchWord(_ w: String) -> Bool {
        let b = Array(w.utf8)
        guard i + b.count <= src.count, Array(src[i..<i+b.count]) == b else { return false }
        for _ in b { advance() }
        return true
    }

    mutating func parseString() throws -> String {
        let quote = src[i]; advance()
        var out: [UInt8] = []
        while !atEnd, src[i] != quote {
            if src[i] == 0x5C { out.append(src[i]); advance(); guard !atEnd else { break } }
            out.append(src[i]); advance()
        }
        guard !atEnd else { throw fail("unterminated string") }
        advance()
        return String(decoding: out, as: UTF8.self)
    }

    mutating func parseNumber() throws -> String {
        let start = i
        while !atEnd {
            let c = src[i]
            let isNum = (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x2D || c == 0x2B
                || c == 0x65 || c == 0x45 || c == 0x78 || c == 0x58
                || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
            if !isNum { break }
            advance()
        }
        guard i > start else { throw fail("expected a value") }
        return text(start, i)
    }

    mutating func parseKey() throws -> String {
        if src[i] == 0x22 || src[i] == 0x27 { return try parseString() }
        let start = i
        while !atEnd {
            let c = src[i]
            let ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24
            if !ok { break }
            advance()
        }
        guard i > start else { throw fail("expected a key") }
        return text(start, i)
    }

    mutating func parseObject() throws -> Node {
        advance()   // {
        var entries: [(String, Node, [String], String?, Bool)] = []
        while true {
            trivia()
            guard !atEnd else { throw fail("unterminated object") }
            if src[i] == 0x7D { advance(); break }
            let (lead, blank) = takeComments()
            let startLine = line
            let key = try parseKey()
            trivia()
            guard !atEnd, src[i] == 0x3A else { throw fail("expected ':' after key \"\(key)\"") }
            advance()
            let value = try parseValue()
            lineOfIndex[entries.count] = startLine
            trivia()
            if !atEnd, src[i] == 0x2C { advance() }
            let trail = trailingComment()
            entries.append((key, value, lead, trail, blank))
        }
        return .object(entries.map { (key: $0.0, node: $0.1, lead: $0.2, trail: $0.3, blankBefore: $0.4) })
    }

    mutating func parseArray() throws -> Node {
        advance()   // [
        var items: [(Node, [String], String?, Bool)] = []
        while true {
            trivia()
            guard !atEnd else { throw fail("unterminated array") }
            if src[i] == 0x5D { advance(); break }
            let (lead, blank) = takeComments()
            let value = try parseValue()
            trivia()
            if !atEnd, src[i] == 0x2C { advance() }
            let trail = trailingComment()
            items.append((value, lead, trail, blank))
        }
        return .array(items.map { (node: $0.0, lead: $0.1, trail: $0.2, blankBefore: $0.3) })
    }
}

// ---------------------------------------------------------------- comments

func harvestComments(_ n: Node) -> [String] {
    var out: [String] = []
    switch n {
    case .object(let e):
        for x in e { out += x.lead; if let t = x.trail { out.append(t) }; out += harvestComments(x.node) }
    case .array(let a):
        for x in a { out += x.lead; if let t = x.trail { out.append(t) }; out += harvestComments(x.node) }
    default: break
    }
    return out
}

// ---------------------------------------------------------------- writer

/// Canonical renderer. A zone object renders on one line with aligned columns;
/// everything else renders block style.
struct Writer {
    static let zoneKeyOrder = ["name", "x", "y", "width", "height", "builtin", "minWidth", "minHeight", "layout"]
    static let topKeyOrder = ["version", "defaults", "layouts", "screens"]

    static func render(_ n: Node, preamble: [String] = []) -> String {
        var s = preamble.map { $0 + "\n" }.joined()
        if !preamble.isEmpty { s += "\n" }
        write(n, into: &s, indent: 0, inZoneArray: false)
        return s.hasSuffix("\n") ? s : s + "\n"
    }

    static func isZoneish(_ n: Node) -> Bool {
        guard case .object(let e) = n else { return false }
        let keys = Set(e.map(\.key))
        if keys.contains("x") && keys.contains("width") { return e.count <= 6 }
        return keys.contains("layout") && e.count <= 4
    }

    static func inlineObject(_ n: Node, widths: [String: Int]) -> String {
        guard case .object(let e) = n else { return "" }
        let sorted = e.sorted { a, b in
            let ia = zoneKeyOrder.firstIndex(of: a.key) ?? 99
            let ib = zoneKeyOrder.firstIndex(of: b.key) ?? 99
            return ia < ib
        }
        var parts: [String] = []
        for (idx, x) in sorted.enumerated() {
            let v = scalar(x.node)
            let isLast = idx == sorted.count - 1
            let pad = isLast ? 0 : max(0, (widths[x.key] ?? v.count) - v.count)
            let sep = isLast ? "" : ","
            parts.append("\(x.key): \(v)\(sep)\(String(repeating: " ", count: pad))")
        }
        return "{ " + parts.joined(separator: " ") + " }"
    }

    static func scalar(_ n: Node) -> String {
        switch n {
        case .string(let s): return "\"\(s)\""
        case .number(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return "?"
        }
    }

    static func write(_ n: Node, into s: inout String, indent: Int, inZoneArray: Bool) {
        let pad = String(repeating: "  ", count: indent)
        switch n {
        case .object(let entries):
            let sorted = entries.sorted { a, b in
                let ia = topKeyOrder.firstIndex(of: a.key) ?? 99
                let ib = topKeyOrder.firstIndex(of: b.key) ?? 99
                if ia == ib { return false }
                return ia < ib
            }
            s += "{\n"
            for x in sorted {
                if x.blankBefore { s += "\n" }
                for c in x.lead { s += pad + "  " + c + "\n" }
                s += pad + "  " + x.key + ": "
                write(x.node, into: &s, indent: indent + 1, inZoneArray: false)
                s += ","
                if let t = x.trail { s += "  " + t }
                s += "\n"
            }
            s += pad + "}"

        case .array(let items):
            let allZones = !items.isEmpty && items.allSatisfy { isZoneish($0.node) }
            var keySets: Set<[String]> = []
            for it in items { if case .object(let e) = it.node { keySets.insert(e.map(\.key).sorted()) } }
            let homogeneous = keySets.count == 1
            var widths: [String: Int] = [:]
            if allZones && homogeneous {
                for it in items {
                    if case .object(let e) = it.node {
                        for x in e { widths[x.key] = max(widths[x.key] ?? 0, scalar(x.node).count) }
                    }
                }
            }
            s += "[\n"
            for it in items {
                if it.blankBefore { s += "\n" }
                for c in it.lead { s += pad + "  " + c + "\n" }
                s += pad + "  "
                if allZones { s += inlineObject(it.node, widths: widths) }
                else { write(it.node, into: &s, indent: indent + 1, inZoneArray: false) }
                s += ","
                if let t = it.trail { s += "  " + t }
                s += "\n"
            }
            s += pad + "]"

        default:
            s += scalar(n)
        }
    }
}

// ---------------------------------------------------------------- editing

/// The kind of thing the visual editor does: reorder a zone, rename it, change
/// its numbers. Comments must follow their node.
func editTree(_ n: Node) -> Node {
    guard case .object(var top) = n else { return n }
    for (ti, entry) in top.enumerated() where entry.key == "layouts" {
        guard case .array(var layouts) = entry.node else { continue }
        for (li, layoutItem) in layouts.enumerated() {
            guard case .object(var layout) = layoutItem.node else { continue }
            for (zi, zonesEntry) in layout.enumerated() where zonesEntry.key == "zones" {
                guard case .array(var zones) = zonesEntry.node else { continue }
                if zones.count >= 2 {
                    let last = zones.removeLast()
                    zones.insert(last, at: 0)              // reorder
                }
                if case .object(var z) = zones[0].node {   // rename + move
                    for (k, e) in z.enumerated() {
                        if e.key == "name" { z[k].node = .string("Renamed") }
                        if e.key == "x" { z[k].node = .number("0.125") }
                    }
                    zones[0].node = .object(z)
                }
                layout[zi].node = .array(zones)
            }
            layouts[li].node = .object(layout)
        }
        top[ti].node = .array(layouts)
    }
    return .object(top)
}

// ---------------------------------------------------------------- run

let sample = try! String(contentsOfFile: "example.json5", encoding: .utf8)

func parse(_ t: String) throws -> (Node, [String]) {
    var p = Parser(t)
    let n = try p.parseDocument()
    return (n, p.preamble)
}

do {
    let (tree, pre) = try parse(sample)
    let originalComments = pre + harvestComments(tree)
    let rendered = Writer.render(tree, preamble: pre)
    try! rendered.write(toFile: "example.canonical.json5", atomically: true, encoding: .utf8)

    _ = try JSONSerialization.jsonObject(with: Data(rendered.utf8), options: [.json5Allowed])
    print("1. Foundation JSON5 accepts it ............... OK")

    let (t2, p2) = try parse(rendered)
    let twice = Writer.render(t2, preamble: p2)
    print("2. Idempotent ................................ \(twice == rendered ? "STABLE byte for byte" : "UNSTABLE")")

    let after = p2 + harvestComments(t2)
    print("3. Comments \(originalComments.count) in / \(after.count) out ................ \(Set(originalComments) == Set(after) ? "0 lost" : "LOST \(Set(originalComments).subtracting(after))")")

    let (t3, p3) = try parse(rendered)
    let edited = Writer.render(editTree(t3), preamble: p3)
    let (t4, p4) = try parse(edited)
    let ec = p4 + harvestComments(t4)
    print("4. After editor reorder+rename+move .......... \(ec.count)/\(originalComments.count) comments survived")
    print("5. Edited output parses ...................... \(((try? JSONSerialization.jsonObject(with: Data(edited.utf8), options: [.json5Allowed])) != nil) ? "OK" : "FAIL")")

    struct Frac: Decodable { let d: Double
        init(from dec: Decoder) throws { let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { d = n; return }
            let s = try c.decode(String.self); let p = s.split(separator: "/")
            guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ratio \(s)") }
            d = a/b } }
    struct Z: Decodable { let name: String; let x: Frac; let y: Frac; let width: Frac; let height: Frac }
    struct L: Decodable { let name: String; let gap: Int?; let zones: [Z] }
    struct C: Decodable { let version: Int; let layouts: [L] }
    let dec = JSONDecoder(); dec.allowsJSON5 = true
    let cfg = try dec.decode(C.self, from: Data(rendered.utf8))
    print("6. Typed decode .............................. v\(cfg.version), \(cfg.layouts.count) layouts, zones \(cfg.layouts.map(\.zones.count))")
    for l in cfg.layouts {
        let rightEdge = l.zones.map { $0.x.d + $0.width.d }.max() ?? 0
        let bottom = l.zones.map { $0.y.d + $0.height.d }.max() ?? 0
        print("   \(l.name.padding(toLength: 16, withPad: " ", startingAt: 0)) max x+w = \(rightEdge)\(rightEdge == 1.0 ? " (exact)" : " <-- NOT EXACT"), max y+h = \(bottom)")
    }
} catch let e as ParseError { print("PARSE ERROR line \(e.line) col \(e.column): \(e.message)") }
catch { print("ERROR \(error)") }
