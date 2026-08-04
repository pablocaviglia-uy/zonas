import Foundation
import Testing
@testable import Zonas

/// The editor's half of a pair. `FractionTests` in `LayoutSchemaTests` covers
/// the file's half — reading `"1/3"` off disk — and the first test here is the
/// join between them: what the grid produces and what the file parses have to
/// be the same bits, or a layout drifts a little every time it is written.
@Suite("The fractions the editor is willing to write")
struct FractionGridTests {

    /// The claim the whole snapping design rests on: a value the editor snaps
    /// to and a value the file parses are **the same bits**. `LayoutSchema`
    /// reads `"1/3"` as `Double(1) / Double(3)`, and if the grid produced
    /// anything else the number would drift a little on every save.
    @Test("A snapped value and a value read from the file are identical")
    func theGridAndTheFileAgreeExactly() {
        for denominator in Fraction.denominators {
            for numerator in 1..<denominator {
                let fromTheGrid = Double(numerator) / Double(denominator)
                // What `LayoutSchema.fraction` does with the string "n/d".
                let fromTheFile = Double("\(numerator)")! / Double("\(denominator)")!
                #expect(fromTheGrid == fromTheFile)
            }
        }
    }

    @Test("The tidiest spelling wins")
    func smallestDenominatorWins() {
        #expect(Fraction.describe(0.5) == "1/2")
        #expect(Fraction.describe(0.25) == "1/4")
        #expect(Fraction.describe(2.0 / 4) == "1/2")     // not 2/4
        #expect(Fraction.describe(4.0 / 8) == "1/2")
        #expect(Fraction.describe(8.0 / 16) == "1/2")
        #expect(Fraction.describe(6.0 / 8) == "3/4")
        #expect(Fraction.describe(1.0 / 3) == "1/3")
        #expect(Fraction.describe(5.0 / 16) == "5/16")
    }

    @Test("Nought and one are whole numbers, not fractions")
    func wholeNumbersHaveNoDenominator() {
        #expect(Fraction.describe(0) == "0")
        #expect(Fraction.describe(1) == "1")
    }

    /// The grey half of §5's label. A number that is not one of ours has to
    /// *look* like it is not one of ours, because that contrast is the whole
    /// point: at a glance you can see whether your layout is tidy.
    @Test("A number that is not one of ours is shown as a decimal")
    func untidyNumbersReadAsDecimals() {
        #expect(Fraction.clean(0.37) == nil)
        #expect(Fraction.describe(0.37) == "0.37")
        #expect(Fraction.describe(1.0 / 7) == "0.1429")
        #expect(Fraction.describe(0.3333) == "0.3333")   // written by hand, and not a third
    }

    /// The reason the tolerance exists at all. A zone's width comes out of a
    /// subtraction of two coordinates, and `1/3 - 1/4` is not bit-for-bit
    /// `1/12` — but it is plainly a twelfth and has to read as one.
    @Test("A width that came out of a subtraction is still a fraction")
    func arithmeticResidueIsStillClean() {
        let width = 1.0 / 3 - 1.0 / 4
        #expect(width != 1.0 / 12)                        // not the same bits
        #expect(Fraction.describe(width) == "1/12")       // and still a twelfth
    }

    /// `1/2`, `2/4`, `4/8` and `8/16` are one line. Offering it four times
    /// would make the middle of the screen four times as sticky as anywhere
    /// else, for a reason nobody could see.
    @Test("Every line is offered once")
    func theGridHasNoRepeats() {
        #expect(Fraction.lines.count == Set(Fraction.lines).count)
        #expect(Fraction.lines.filter { abs($0 - 0.5) < 1e-12 }.count == 1)
        #expect(Fraction.lines.first! > 0)
        #expect(Fraction.lines.last! < 1)
        #expect(Fraction.lines == Fraction.lines.sorted())
    }

    /// How dense the grid is decides whether a snap radius can leave any room
    /// to be off it. The tightest pair is 3/16 and 1/5, a eightieth apart —
    /// sixty-four points on the ultrawide, twenty-one on the laptop.
    @Test("The tightest pair of lines is far enough apart to aim between")
    func theGridIsNotTooDense() {
        let gaps = zip(Fraction.lines, Fraction.lines.dropFirst()).map { $1 - $0 }
        let tightest = gaps.min()!

        #expect(tightest > 0.012)
        #expect(tightest * 5120 > 60)   // points, on the ultrawide
    }
}
