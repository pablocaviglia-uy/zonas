import Foundation

/// The fractions this project is willing to write down.
///
/// **The editor snaps to exactly the numbers the format can write.** That is
/// the whole idea and it is not a coincidence to be maintained by hand: a
/// layout dragged into place produces `1/3`, which `LayoutSchema.fraction`
/// reads back as `Double(1) / Double(3)` — the same bits — so the value
/// survives being written and read without drifting. A snapping grid that did
/// not line up with the file's vocabulary would put `0.3333333333333333` in
/// somebody's dotfiles and the whole thesis with it.
///
/// The denominators are §5's: 2, 3, 4, 5, 6, 8, 10, 12, 16. Halves through
/// sixths cover almost every layout anybody draws; eighths and sixteenths are
/// what an ultrawide wants; tenths and twelfths are there because people think
/// in percentages and in twelve-column grids.
enum Fraction {

    static let denominators = [2, 3, 4, 5, 6, 8, 10, 12, 16]

    /// How close a value has to be to count as that fraction.
    ///
    /// A billionth of a screen is five millionths of a point on the ultrawide.
    /// It is not a fudge factor for sloppy input — it is there because
    /// `1/3 - 1/4` is not bit-for-bit `1/12`, and a zone that came out of a
    /// subtraction has to still be recognised as the twelfth it plainly is.
    static let tolerance = 1e-9

    /// The tidiest way to write this value, smallest denominator first, or
    /// `nil` if it is not one of ours.
    ///
    /// Smallest first is what turns `2/4` into `1/2`. Reducing afterwards would
    /// work too and this way there is nothing to reduce.
    static func clean(_ value: Double) -> (numerator: Int, denominator: Int)? {
        guard value.isFinite, value >= 0, value <= 1 else { return nil }
        for denominator in denominators {
            let scaled = value * Double(denominator)
            let numerator = scaled.rounded()
            guard abs(scaled - numerator) < tolerance * Double(denominator) else { continue }
            // 0 and 1 are whole numbers wearing a denominator; `describe`
            // spells them without one.
            return (Int(numerator), denominator)
        }
        return nil
    }

    /// How a value reads on screen: `1/3` when it is one of ours, a decimal
    /// when it is not.
    ///
    /// §5 wants both on every zone, all the time, so that **you can see at a
    /// glance whether your layout is tidy**. It is the file's thesis made
    /// visible inside the GUI: the editor is not hiding the numbers from you,
    /// it is showing you which ones you are about to write.
    static func describe(_ value: Double) -> String {
        if let (numerator, denominator) = clean(value) {
            if numerator == 0 { return "0" }
            if numerator == denominator { return "1" }
            return "\(numerator)/\(denominator)"
        }
        // Four decimals is where a fraction of a 5120-point screen stops being
        // half a point, so it is the last digit that could mean anything.
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Every line the grid offers, sorted and without repeats.
    ///
    /// `1/2`, `2/4`, `4/8` and `8/16` are one line, and offering it four times
    /// would make the middle of the screen four times as sticky as anywhere
    /// else for no reason anybody could see.
    static let lines: [Double] = {
        var seen: [Double] = []
        for denominator in denominators {
            for numerator in 1..<denominator {
                let value = Double(numerator) / Double(denominator)
                if !seen.contains(where: { abs($0 - value) < tolerance }) { seen.append(value) }
            }
        }
        return seen.sorted()
    }()
}
