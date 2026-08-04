import Foundation

extension LayoutSyntax {

    /// The JSON5 tokenizer and tree builder.
    ///
    /// It works over UTF-8 bytes rather than `Character`s because the only
    /// things it makes decisions about are ASCII punctuation, and everything
    /// else —accents, box-drawing characters in an ASCII diagram, emoji in a
    /// zone name— is copied through untouched as a byte range.
    struct Parser {

        private let source: [UInt8]
        private var index = 0
        private var line = 1
        private var column = 1

        /// Comments seen but not yet attached to anything.
        private var pending: [String] = []
        private var sawBlankLine = false

        init(_ text: String) {
            source = Array(text.utf8)
        }

        // MARK: - Document

        mutating func parseDocument() throws -> Document {
            skipTrivia()
            let (preamble, _) = takePending()
            let root = try parseValue()
            skipTrivia()
            guard atEnd else { throw fail("trailing content after the top-level value") }
            // Anything after the top-level value has nowhere to live. Saying so
            // beats dropping it silently on the next write.
            guard pending.isEmpty else { throw fail("a comment after the closing brace has nothing to attach to") }
            return Document(preamble: preamble, root: root)
        }

        // MARK: - Values

        private mutating func parseValue() throws -> Node {
            skipTrivia()
            guard !atEnd else { throw fail("unexpected end of file") }

            switch source[index] {
            case Byte.leftBrace: return try parseObject()
            case Byte.leftBracket: return try parseArray()
            case Byte.doubleQuote, Byte.singleQuote: return .string(try parseString())
            default:
                if match("true") { return .bool(true) }
                if match("false") { return .bool(false) }
                if match("null") { return .null }
                return .number(try parseNumber())
            }
        }

        private mutating func parseObject() throws -> Node {
            advance()   // {
            var members: [Member] = []

            while true {
                skipTrivia()
                guard !atEnd else { throw fail("unterminated object") }
                if source[index] == Byte.rightBrace { advance(); break }

                let (leading, blank) = takePending()
                let key = try parseKey()
                skipTrivia()
                guard !atEnd, source[index] == Byte.colon else {
                    throw fail("expected ':' after the key \"\(key)\"")
                }
                advance()

                let value = try parseValue()
                skipTrivia()
                if !atEnd, source[index] == Byte.comma { advance() }

                members.append(Member(key: key, node: value,
                                      comments: Comments(leading: leading,
                                                         trailing: takeTrailingComment(),
                                                         blankLineBefore: blank)))
            }
            return .object(members)
        }

        private mutating func parseArray() throws -> Node {
            advance()   // [
            var elements: [Element] = []

            while true {
                skipTrivia()
                guard !atEnd else { throw fail("unterminated array") }
                if source[index] == Byte.rightBracket { advance(); break }

                let (leading, blank) = takePending()
                let value = try parseValue()
                skipTrivia()
                if !atEnd, source[index] == Byte.comma { advance() }

                elements.append(Element(node: value,
                                        comments: Comments(leading: leading,
                                                           trailing: takeTrailingComment(),
                                                           blankLineBefore: blank)))
            }
            return .array(elements)
        }

        private mutating func parseKey() throws -> String {
            if source[index] == Byte.doubleQuote || source[index] == Byte.singleQuote {
                return try parseString()
            }
            let start = index
            while !atEnd, Byte.isIdentifier(source[index]) { advance() }
            guard index > start else { throw fail("expected a key") }
            return text(from: start, to: index)
        }

        /// Reads a quoted string, keeping escape sequences **verbatim**.
        ///
        /// Decoding `\n` into a newline here would mean deciding how to encode
        /// it again on the way out, and the answer differs from what the user
        /// wrote often enough to be a nuisance in a file meant to be read.
        private mutating func parseString() throws -> String {
            let quote = source[index]
            advance()
            var contents: [UInt8] = []

            while !atEnd, source[index] != quote {
                if source[index] == Byte.backslash {
                    contents.append(source[index])
                    advance()
                    guard !atEnd else { break }
                }
                contents.append(source[index])
                advance()
            }
            guard !atEnd else { throw fail("unterminated string") }
            advance()
            return String(decoding: contents, as: UTF8.self)
        }

        private mutating func parseNumber() throws -> String {
            // The first byte has to actually start a number. Hex digits are
            // accepted further in, so without this a bare word as a value
            // —`{ x: foo }`— would come back as the number "f" and the error
            // would surface two tokens later, pointing at the wrong place.
            guard !atEnd, Byte.startsNumber(source[index]) else { throw fail("expected a value") }

            let start = index
            while !atEnd, Byte.continuesNumber(source[index]) { advance() }
            return text(from: start, to: index)
        }

        // MARK: - Trivia and comments

        /// Eats whitespace and comments, keeping the comments verbatim.
        private mutating func skipTrivia() {
            var newlines = 0

            while !atEnd {
                let byte = source[index]

                if byte == Byte.space || byte == Byte.tab || byte == Byte.carriageReturn {
                    advance()
                } else if byte == Byte.newline {
                    newlines += 1
                    if newlines > 1 { sawBlankLine = true }
                    advance()
                } else if byte == Byte.slash, peek(1) == Byte.slash {
                    let start = index
                    while !atEnd, source[index] != Byte.newline { advance() }
                    pending.append(text(from: start, to: index))
                    newlines = 0
                } else if byte == Byte.slash, peek(1) == Byte.star {
                    let start = index
                    advance(); advance()
                    while !atEnd, !(source[index] == Byte.star && peek(1) == Byte.slash) { advance() }
                    if !atEnd { advance(); advance() }
                    pending.append(text(from: start, to: index))
                    newlines = 0
                } else {
                    break
                }
            }
        }

        private mutating func takePending() -> ([String], Bool) {
            defer { pending = []; sawBlankLine = false }
            return (pending, sawBlankLine)
        }

        /// A comment on the same line as the value just parsed belongs to that
        /// value. Anything after a newline belongs to whatever comes next.
        ///
        /// That single rule is what decides where every comment in the file
        /// ends up, and it matches how people actually write them.
        private mutating func takeTrailingComment() -> String? {
            var ahead = index
            while ahead < source.count,
                  source[ahead] == Byte.space || source[ahead] == Byte.tab { ahead += 1 }
            guard ahead + 1 < source.count,
                  source[ahead] == Byte.slash, source[ahead + 1] == Byte.slash else { return nil }

            while index < ahead { advance() }
            let start = index
            while !atEnd, source[index] != Byte.newline { advance() }
            return text(from: start, to: index)
        }

        // MARK: - Cursor

        private var atEnd: Bool { index >= source.count }

        private func peek(_ offset: Int = 0) -> UInt8? {
            index + offset < source.count ? source[index + offset] : nil
        }

        private mutating func advance() {
            if source[index] == Byte.newline {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }

        private mutating func match(_ word: String) -> Bool {
            let bytes = Array(word.utf8)
            guard index + bytes.count <= source.count,
                  Array(source[index ..< index + bytes.count]) == bytes else { return false }
            for _ in bytes { advance() }
            return true
        }

        private func text(from start: Int, to end: Int) -> String {
            String(decoding: source[start ..< end], as: UTF8.self)
        }

        private func fail(_ message: String) -> ParseError {
            ParseError(line: line, column: column, message: message)
        }
    }
}

/// The ASCII bytes the parser makes decisions about.
///
/// Named rather than written as hex at the call sites: `0x7B` is a brace to
/// nobody, and the parser is exactly the kind of code where one wrong constant
/// produces behaviour that looks almost right.
private enum Byte {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let doubleQuote: UInt8 = 0x22
    static let dollar: UInt8 = 0x24
    static let singleQuote: UInt8 = 0x27
    static let star: UInt8 = 0x2A
    static let plus: UInt8 = 0x2B
    static let comma: UInt8 = 0x2C
    static let minus: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let colon: UInt8 = 0x3A
    static let leftBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let rightBracket: UInt8 = 0x5D
    static let underscore: UInt8 = 0x5F
    static let leftBrace: UInt8 = 0x7B
    static let rightBrace: UInt8 = 0x7D

    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }
    static func isHexLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    static func isIdentifier(_ b: UInt8) -> Bool {
        isLetter(b) || isDigit(b) || b == underscore || b == dollar
    }

    static func startsNumber(_ b: UInt8) -> Bool {
        isDigit(b) || b == dot || b == minus || b == plus
    }

    /// Deliberately loose: it accepts hex digits and `x`, so `0xFF` comes
    /// through in one piece. What it must not do is accept a byte that could
    /// start the next token.
    static func continuesNumber(_ b: UInt8) -> Bool {
        isDigit(b) || isHexLetter(b) || b == dot || b == minus || b == plus
            || b == 0x65 || b == 0x45      // e, E — exponents
            || b == 0x78 || b == 0x58      // x, X — hex
    }
}
