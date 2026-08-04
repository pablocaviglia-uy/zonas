import Foundation
import Testing
@testable import Zonas

/// A file with a comment in every position the format allows, because that is
/// the lesson §4 already paid for once: a conservation test only bites if the
/// fixture has something to lose in the position the writer breaks.
private let file = """
// Zonas layout — the preamble, which has no node to hang off.
//
//   ┌─────┬───────────┐
//   │     │           │
//   └─────┴───────────┘

{
  version: 1,  // the format, not the app

  defaults: {
    modifier: "shift",  // shift | control | option | command
    gap: 8,
    margin: 0,
  },

  name: "Three Columns",

  // Editor in the middle, docs on the left.
  zones: [
    // the reading one
    { name: "Left",   x: 0,      y: 0, width: "1/4", height: 1 },  // keep it first
    { name: "Center", x: "1/4",  y: 0, width: "1/2", height: 1 },
    // the work one
    { name: "Right",  x: "3/4",  y: 0, width: "1/4", height: 1 },  // keep it last
  ],
}

// A note at the end of the file, which is an ordinary thing to write.
"""

private func document(_ text: String = file) throws -> EditorDocument {
    EditorDocument(try Layout(LayoutSyntax.parse(text)))
}

private func zones(of text: String) throws -> [Zone] {
    try Layout(LayoutSyntax.parse(text)).zones
}

@Suite("Putting an edited layout back in its file")
struct LayoutWriterTests {

    // MARK: - Rule 2

    /// The merge condition, and the first thing to check about any writer in
    /// this project. Every comment in the file has to come out the other side.
    @Test("An edit that touches one zone loses no comment")
    func nothingIsLostOnAnOrdinaryEdit() throws {
        var doc = try document()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.5, within: 0.01)!
        doc.move(edge, to: 1.0 / 3, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        let before = LayoutSyntax.comments(of: try LayoutSyntax.parse(file))
        let after = LayoutSyntax.comments(of: try LayoutSyntax.parse(written))
        #expect(LayoutSyntax.lost(from: before, to: after).isEmpty)
        #expect(before.count == 13)   // and there really were that many to lose
    }

    /// The preamble, the ASCII diagram and the note after the closing brace have
    /// no node to attach to, which is exactly why they are the ones a writer
    /// drops.
    @Test("The header, the diagram and the note at the end all survive")
    func theHomelessCommentsSurvive() throws {
        var doc = try document()
        doc.split(rid: doc.zones[1].rid, at: 0.5, .vertical, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(written.contains("│     │           │"))
        #expect(written.contains("// A note at the end of the file"))
        #expect(written.contains("// the format, not the app"))
    }

    /// A comment sitting beside a zone stays beside **that** zone, not beside
    /// whichever zone ends up at that index afterwards. Splitting inserts a new
    /// element in the middle, so this is where an index-based writer goes wrong.
    @Test("A zone's own comments follow it past an insertion")
    func commentsStayWithTheirZone() throws {
        var doc = try document()
        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)
        let lines = written.split(separator: "\n").map(String.init)

        let readingOne = lines.firstIndex { $0.contains("// the reading one") }!
        let left = lines.firstIndex { $0.contains("name: \"Left\"") }!
        let workOne = lines.firstIndex { $0.contains("// the work one") }!
        let right = lines.firstIndex { $0.contains("name: \"Right\"") }!

        #expect(readingOne == left - 1)
        #expect(workOne == right - 1)
        #expect(written.contains("keep it last"))
    }

    /// The one legitimate way a comment leaves this file. A writer that never
    /// loses one cannot delete a zone; a writer that deletes zones cannot make
    /// `fmt`'s promise. The difference is this, and only this.
    @Test("Deleting a zone takes its own comments and nobody else's")
    func deletingTakesOnlyItsOwnComments() throws {
        var doc = try document()
        doc.delete(rid: doc.zones[2].rid)          // "Right", with two comments

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(!written.contains("// the work one"))
        #expect(!written.contains("keep it last"))
        // Everything else is still there.
        #expect(written.contains("// the reading one"))
        #expect(written.contains("keep it first"))
        #expect(written.contains("// A note at the end of the file"))
        #expect(written.contains("│     │           │"))
    }

    /// A comment on a key *inside* a zone, which is the position the renderer
    /// used to drop — it could not fit one on an inlined row, so the whole file
    /// became unwritable and `zonas fmt` refused with a message saying it was a
    /// bug in Zonas. It was. The array now falls back to block style, and the
    /// zone this is attached to is one that gets edited.
    @Test("A comment inside a zone survives an edit to that zone")
    func commentsInsideAZoneSurvive() throws {
        let text = """
        {
          version: 1,
          name: "L",
          zones: [
            {
              name: "Left",
              // a quarter, because the sidebar is 400 points
              x: 0, y: 0, width: "1/4", height: 1,
            },
            { name: "Right", x: "1/4", y: 0, width: "3/4", height: 1 },
          ],
        }
        """
        var doc = try document(text)
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.5, within: 0.01)!
        doc.move(edge, to: 1.0 / 3, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: text)

        #expect(written.contains("// a quarter, because the sidebar is 400 points"))
        #expect(written.contains("\"1/3\""))
    }

    /// Which comments are *allowed* to disappear. This is the whole of what
    /// stretch 5 added to the merge condition, so it is checked directly rather
    /// than only through a writer that happens not to lose anything.
    @Test("Only the deleted zone's comments are excused")
    func survivorsExcusesExactlyTheDeletedZone() throws {
        let parsed = try LayoutSyntax.parse(file)
        guard case .object(let members) = parsed.root,
              let listed = members.first(where: { $0.key == "zones" }),
              case .array(let elements) = listed.node else { return #expect(Bool(false)) }

        let all = LayoutSyntax.comments(of: parsed)
        let kept = LayoutWriter.survivors(of: parsed, dropping: [2], in: elements)

        #expect(all.count == 13)
        #expect(kept.count == 11)
        #expect(!kept.contains("// the work one"))
        #expect(!kept.contains("// keep it last"))
        #expect(kept.contains("// the reading one"))
        #expect(kept.contains("// keep it first"))
        // Nothing is excused when nothing is deleted.
        #expect(LayoutWriter.survivors(of: parsed, dropping: [], in: elements).count == 13)
    }

    // MARK: - Rule 4

    /// A key this version of the app has never heard of has to come back out
    /// exactly as it went in, including on a zone that was edited.
    @Test("Keys from the future survive an edit to the zone they are on")
    func unknownKeysSurvive() throws {
        let text = """
        {
          version: 1,
          name: "L",
          hooks: { onSnap: "say hi" },
          zones: [
            { name: "A", x: 0, y: 0, width: "1/2", height: 1, opacity: 0.8 },
            { name: "B", x: "1/2", y: 0, width: "1/2", height: 1 },
          ],
        }
        """
        var doc = try document(text)
        let edge = doc.edge(along: .vertical, near: 0.5, across: 0.5, within: 0.01)!
        doc.move(edge, to: 1.0 / 3, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: text)

        #expect(written.contains("opacity: 0.8"))
        #expect(written.contains("onSnap"))
        #expect(written.contains("say hi"))
    }

    @Test("Everything that is not a zone is left alone")
    func theRestOfTheFileIsUntouched() throws {
        var doc = try document()
        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(written.contains("version: 1"))
        #expect(written.contains("modifier: \"shift\""))
        #expect(written.contains("gap: 8"))
        #expect(written.contains("name: \"Three Columns\""))
    }

    // MARK: - What the numbers look like

    /// §5 in one line: you snap to the grid and the file is written as `1/3`.
    /// Three columns written as ratios add up to exactly one; the same three as
    /// `0.3333` leave a sliver that is invisible in the file and maddening on
    /// screen.
    @Test("A snapped number is written as a ratio")
    func cleanNumbersComeOutAsRatios() throws {
        var doc = try document()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.5, within: 0.01)!
        doc.move(edge, to: 1.0 / 3, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(written.contains("\"1/3\""))
        #expect(!written.contains("0.3333"))
        // And the file still adds up: the three widths sum to exactly one.
        let widths = try zones(of: written).map(\.width)
        #expect(widths.reduce(0, +) == 1)
    }

    /// Dragging one divider used to rewrite every number in the file: a zone
    /// nobody had touched went from `0.75` to `"3/4"` — the same number, spelled
    /// the way this writer prefers rather than the way its author wrote it.
    /// `LayoutSyntax` promises that `.25` stays `.25`, and a writer that
    /// restyles the untouched half of the file breaks that promise from the
    /// other end.
    @Test("A zone nobody touched is left exactly as it was written")
    func untouchedZonesKeepTheirSpelling() throws {
        let text = """
        {
          version: 1,
          name: "L",
          zones: [
            { name: "A", x: 0,    y: 0, width: .25,   height: 1 },
            { name: "B", x: .25,  y: 0, width: "25%", height: 1 },
            { name: "C", x: 0.50, y: 0, width: 0.50,  height: 1 },
          ],
        }
        """
        var doc = try document(text)
        // Move the line between B and C only.
        let edge = doc.edge(along: .vertical, near: 0.5, across: 0.5, within: 0.01)!
        doc.move(edge, to: 5.0 / 8, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: text)

        // Padding moves when a column gets wider, so the assertions are about
        // the spellings and not about the spaces between them.
        #expect(written.contains("width: .25"))     // A's width, verbatim — never touched
        #expect(written.contains("x: .25"))         // B's x, verbatim — the line moved, not this
        #expect(written.contains("x: 0,"))          // and A's x is still a bare nought
        #expect(!written.contains("\"25%\""))       // B's width did move
        #expect(written.contains("width: \"3/8\""))  // ...and reads as the fraction it now is
        #expect(written.contains("x: \"5/8\""))     // C's origin moved with it
        #expect(!written.contains("0.50"))
    }

    @Test("Nought and one are written as numbers, not as ratios")
    func wholeNumbersStayWhole() throws {
        var doc = try document()
        doc.split(rid: doc.zones[0].rid, at: 0.125, .vertical, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(written.contains("x: 0,"))
        #expect(!written.contains("\"0/1\""))
        #expect(!written.contains("\"1/1\""))
    }

    /// What ⌥ produces. Seventeen significant figures in a file somebody is
    /// meant to read is noise pretending to be precision; six decimals is five
    /// thousandths of a point on the ultrawide.
    @Test("A number off the grid is written as a short decimal")
    func untidyNumbersAreWrittenShort() throws {
        var doc = try document()
        let edge = doc.edge(along: .vertical, near: 0.25, across: 0.5, within: 0.01)!
        doc.move(edge, to: 0.377893518518, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(written.contains("0.377894"))
        #expect(!written.contains("0.377893518518"))
    }

    // MARK: - Round trips

    /// The claim the whole write path rests on: what the editor holds and what
    /// the file says are the same layout, so reading the file back gives the
    /// document you were looking at.
    @Test("What is written reads back as what was edited")
    func theFileMeansWhatTheEditorMeant() throws {
        var doc = try document()
        doc.split(rid: doc.zones[1].rid, at: 0.5, .vertical, minimum: 0.01)
        doc.delete(rid: doc.zones[0].rid)
        let edge = doc.edge(along: .vertical, near: 0.5, across: 0.5, within: 0.01)!
        doc.move(edge, to: 5.0 / 8, minimum: 0.01)

        let written = try LayoutWriter.apply(doc, to: file)

        #expect(try zones(of: written) == doc.layout.zones)
    }

    @Test("Writing twice with no edit in between changes nothing")
    func writingIsIdempotent() throws {
        var doc = try document()
        doc.split(rid: doc.zones[0].rid, at: 0.1, .vertical, minimum: 0.01)

        let once = try LayoutWriter.apply(doc, to: file)
        let twice = try LayoutWriter.apply(try document(once), to: once)

        #expect(once == twice)
    }

    @Test("A file that is not a layout is refused rather than overwritten")
    func nonsenseIsRefused() throws {
        let doc = try document()
        #expect(throws: LayoutWriter.NotALayout.self) {
            try LayoutWriter.apply(doc, to: "[1, 2, 3]")
        }
    }
}
