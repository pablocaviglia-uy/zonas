import Foundation
import Testing
@testable import Zonas

/// The date rule that a day-spanning log needs to be filterable at all.
@Suite("Marking the day in the log")
struct LogDayTests {

    @Test("The first line of a day is preceded by a dated rule, and later ones are not")
    func aRulePerDay() throws {
        try inTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("Zonas.log")
            let previous = Log.url
            Log.url = url
            defer { Log.url = previous }

            Log.write("first")
            Log.write("second")
            Log.waitForWrites()

            let text = try String(contentsOf: url, encoding: .utf8)
            let rules = text.components(separatedBy: "\n").filter { $0.hasPrefix("-- ") }

            #expect(rules.count == 1, "one rule for one day, got \(rules)")
            #expect(rules.first?.contains(Log.today) == true)
            #expect(text.contains("first"))
            #expect(text.contains("second"))
        }
    }
}
