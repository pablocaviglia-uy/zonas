import Foundation
import Testing
@testable import Zonas

/// The hand-written config the format is measured against: ASCII diagrams,
/// ratios, overlapping zones, comments in every position the format allows.
private func exampleFile() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/example", withExtension: "json5"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Reading and writing the file back")
struct LayoutSyntaxTests {

    /// It has to still be JSON5 afterwards. Everything else is decoration if
    /// Foundation cannot read what we wrote.
    @Test("What the writer produces is accepted by Foundation's JSON5 reader")
    func theOutputIsStillJSON5() throws {
        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(try exampleFile()))

        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: Data(rendered.utf8), options: [.json5Allowed])
        }
    }

    /// Rendering something already canonical must change nothing at all, or
    /// every save would produce a diff and the format would be unusable in git.
    @Test("Rendering twice is stable byte for byte")
    func renderingIsIdempotent() throws {
        let once = LayoutSyntax.render(try LayoutSyntax.parse(try exampleFile()))
        let twice = LayoutSyntax.render(try LayoutSyntax.parse(once))

        #expect(twice == once)
    }

    /// **The merge condition.**
    ///
    /// Not a nice-to-have and not implied by the test above. To re-run the
    /// claim rather than believe it: delete the line in `LayoutSyntax.write`
    /// that emits `element.comments.trailing`, and watch idempotency pass byte
    /// for byte while this fails with
    /// `["// the work one", "// keep it last"]`.
    ///
    /// That is also why the fixture carries a comment in every position the
    /// format allows. The first version of it had none on an array element, so
    /// this test passed against a writer that had been broken on purpose.
    @Test("Not one comment is lost")
    func noCommentIsLost() throws {
        let document = try LayoutSyntax.parse(try exampleFile())

        let lost = try LayoutSyntax.commentsLost(rendering: document)

        #expect(lost.isEmpty, "the writer dropped \(lost.count): \(lost)")
        #expect(LayoutSyntax.comments(of: document).count == 46,
                "the fixture changed — if that was deliberate, update the count")
    }

    /// The header of the file has nowhere to attach: there is no node above the
    /// opening brace. Without a slot of its own it is the first thing a write
    /// would throw away, and it is the twenty lines that explain the file.
    @Test("The header above the opening brace survives")
    func thePreambleSurvives() throws {
        let document = try LayoutSyntax.parse(try exampleFile())

        #expect(document.preamble.count > 5)
        #expect(LayoutSyntax.render(document).hasPrefix(document.preamble[0]))
    }

    /// Rule 4 of the plan, and the reason the writer renders from the tree
    /// rather than from the `Codable` structs. A version of the app that has
    /// never heard of `hooks` must not delete somebody's `hooks` block.
    @Test("A key this version knows nothing about comes back out")
    func unknownKeysSurvive() throws {
        let source = """
        {
          name: "Three Columns",
          hooks: { onSnap: "say hello" },   // from a newer version
          zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ],
        }
        """

        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(source))

        #expect(rendered.contains("hooks"))
        #expect(rendered.contains("onSnap"))
        #expect(rendered.contains("// from a newer version"))
    }

    /// Swift's sort is not stable, so keys the format has no opinion about
    /// could otherwise come out in either order — non-deterministically, and
    /// precisely for the unknown keys the tree exists to protect.
    @Test("Keys the format has no opinion about keep their order")
    func unknownKeysKeepTheirOrder() throws {
        let source = "{ zeta: 1, alpha: 2, mu: 3 }"

        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(source))
        let order = ["zeta", "alpha", "mu"].map { rendered.range(of: $0)!.lowerBound }

        #expect(order == order.sorted())
    }

    /// The zone table is what makes the geometry visible at a glance and what
    /// makes changing one zone a one-line diff.
    @Test("Zones render as an aligned table")
    func zonesAreAligned() throws {
        let source = """
        { zones: [
          { name: "Left", x: 0, y: 0, width: 0.25, height: 1 },
          { name: "Center", x: 0.25, y: 0, width: 0.5, height: 1 },
        ] }
        """

        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(source))
        let columns = rendered.split(separator: "\n")
            .filter { $0.contains("name:") }
            .compactMap { line in
                line.range(of: "width:").map { line.distance(from: line.startIndex, to: $0.lowerBound) }
            }

        #expect(columns.count == 2)
        #expect(Set(columns).count == 1, "the columns did not line up:\n\(rendered)")
    }

    /// Padding a heterogeneous list produces columns that line up with nothing,
    /// so those stay block style.
    @Test("A list of unlike objects is not squeezed onto one line each")
    func unlikeObjectsAreNotInlined() throws {
        let source = """
        { things: [
          { name: "a", x: 0 },
          { name: "b", y: 0, extra: true },
        ] }
        """

        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(source))

        #expect(!rendered.contains("{ name: \"a\""))
    }

    @Test("Numbers are written back exactly as they were typed")
    func numbersAreVerbatim() throws {
        let rendered = LayoutSyntax.render(try LayoutSyntax.parse("{ a: .25, b: 0.50, c: 1e3 }"))

        #expect(rendered.contains(".25"))
        #expect(rendered.contains("0.50"))
        #expect(rendered.contains("1e3"))
    }

    /// A double quote inside single quotes is legal JSON5 and would end the
    /// string early on the way out.
    @Test("A quote inside a name does not break the file")
    func quotesInsideStringsAreEscaped() throws {
        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(#"{ name: 'say "hi"' }"#))

        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: Data(rendered.utf8), options: [.json5Allowed])
        }
        #expect(LayoutSyntax.render(try LayoutSyntax.parse(rendered)) == rendered)
    }
}

@Suite("Saying where the file is broken")
struct LayoutSyntaxErrorTests {

    /// "The file does not parse" is not something anybody can act on.
    @Test("An error names the line and the column")
    func errorsCarryAPosition() throws {
        let source = """
        {
          name: "Three Columns",
          zones: [
            { name "Left", x: 0 },
          ],
        }
        """

        let error = #expect(throws: LayoutSyntax.ParseError.self) {
            try LayoutSyntax.parse(source)
        }

        #expect(error?.line == 4)
        #expect(error?.message == #"expected ':' after the key "name""#)
    }

    /// Without the check that a number actually starts like one, a bare word as
    /// a value comes back as the number "f" and the error surfaces two tokens
    /// later, pointing somewhere else entirely.
    @Test("A bare word as a value fails where the word is")
    func bareWordsFailInPlace() throws {
        let error = #expect(throws: LayoutSyntax.ParseError.self) {
            try LayoutSyntax.parse("{ x: foo }")
        }

        #expect(error?.message == "expected a value")
    }

    @Test("An unterminated object says so")
    func unterminatedObject() throws {
        #expect(throws: LayoutSyntax.ParseError.self) {
            try LayoutSyntax.parse("{ name: \"x\", ")
        }
    }
}

@Suite("The conservation check itself")
struct CommentConservationTests {

    /// The merge condition guarantees the writer keeps every comment. Nothing
    /// guaranteed that the check could still tell — so this tests the test.
    @Test("A dropped comment is reported")
    func aDroppedCommentIsCaught() {
        let before = ["// the work one", "// keep it last", "// header"]
        let after = ["// the work one", "// header"]

        #expect(LayoutSyntax.lost(from: before, to: after) == ["// keep it last"])
    }

    /// Comparing sets, which is the obvious implementation and the one the
    /// prototype used, calls this survived.
    @Test("One of two identical comments going missing is still a loss")
    func repeatsAreCounted() {
        let before = ["// left", "// left"]
        let after = ["// left"]

        #expect(LayoutSyntax.lost(from: before, to: after) == ["// left"])
    }

    @Test("Nothing lost reads as nothing lost")
    func survivalIsQuiet() {
        let comments = ["// a", "// b", "// a"]

        #expect(LayoutSyntax.lost(from: comments, to: comments.reversed()).isEmpty)
    }
}

@Suite("The file the first launch writes")
struct SeedIsCanonicalTests {

    /// The seed was written by hand. If the canonical writer would produce
    /// anything else, then the first thing a user sees is not what the format
    /// looks like — and the first `zonas fmt` would reformat the file that is
    /// supposed to be the format's own documentation.
    @Test("The seed is already exactly what the writer would produce")
    func theSeedIsCanonical() throws {
        let rendered = LayoutSyntax.render(try LayoutSyntax.parse(LayoutFile.seed))

        #expect(rendered == LayoutFile.seed)
    }

    @Test("And every comment in it survives a round trip")
    func theSeedKeepsItsComments() throws {
        let lost = try LayoutSyntax.commentsLost(rendering: LayoutSyntax.parse(LayoutFile.seed))

        #expect(lost.isEmpty, "lost \(lost)")
    }
}

@Suite("What it does not preserve")
struct LayoutSyntaxLimitsTests {

    /// Said here rather than discovered later.
    ///
    /// A block comment is one comment, kept verbatim, newlines and all — so it
    /// survives, but the writer indents it as a unit and the lines after the
    /// first keep whatever indentation they had in the original. Line comments
    /// do not have this problem, and they are what the format uses everywhere.
    @Test("A multi-line block comment survives, but is not re-indented")
    func multiLineBlockComments() throws {
        let source = """
        {
        /* one
           two */
        name: "x",
        }
        """

        let document = try LayoutSyntax.parse(source)
        let rendered = LayoutSyntax.render(document)

        #expect(try LayoutSyntax.commentsLost(rendering: document).isEmpty)
        #expect(rendered.contains("/* one\n   two */"))
        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: Data(rendered.utf8), options: [.json5Allowed])
        }
    }
}

@Suite("Comments with nothing to attach to")
struct DocumentLevelCommentTests {

    /// Found by running it: appending a note to the end of the real config file
    /// was rejected, and the whole layout went with it. Adding a note at the end
    /// of a file is an ordinary thing to do.
    @Test("A note after the closing brace survives instead of being refused")
    func theEpilogueSurvives() throws {
        let source = """
        {
          name: "Three Columns",
          zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ],
        }

        // a note I left myself
        """

        let document = try LayoutSyntax.parse(source)

        #expect(document.epilogue == ["// a note I left myself"])
        #expect(try LayoutSyntax.commentsLost(rendering: document).isEmpty)
        #expect(LayoutSyntax.render(document).hasSuffix("// a note I left myself\n"))
    }

    /// And the layout still reads, which is the half that actually broke.
    @Test("The layout under a trailing note still reads")
    func theLayoutStillReads() throws {
        let layout = try Layout(LayoutSyntax.parse("""
        { name: "L", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }
        // trailing
        """))

        #expect(layout.name == "L")
    }

    @Test("Rendering a document with a note at each end is still stable")
    func stillIdempotent() throws {
        let source = """
        // above

        { name: "L", zones: [ { name: "All", x: 0, y: 0, width: 1, height: 1 } ] }

        // below
        """

        let once = LayoutSyntax.render(try LayoutSyntax.parse(source))
        let twice = LayoutSyntax.render(try LayoutSyntax.parse(once))

        #expect(twice == once)
        #expect(once.contains("// above"))
        #expect(once.contains("// below"))
    }
}
