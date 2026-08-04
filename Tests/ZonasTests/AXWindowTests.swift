import Foundation
import Testing
@testable import Zonas

/// Only the pure half. Everything else in `AXWindow` needs a real window
/// belonging to another process, and that is not something a unit test gets to
/// have.
@Suite("Noticing that an app applied something else")
struct AXWindowTests {

    private let asked = CGRect(x: 4, y: 37, width: 424, height: 534)

    @Test("What was asked for is not worth mentioning")
    func identicalIsQuiet() {
        #expect(AXWindow.differs(asked: asked, applied: asked) == false)
    }

    /// Apps that round to whole points must not put a line in the log at the
    /// end of every drag.
    @Test("Rounding to whole points is not a difference")
    func roundingIsQuiet() {
        let rounded = CGRect(x: 4.4, y: 36.6, width: 423.5, height: 534.5)

        #expect(AXWindow.differs(asked: asked, applied: rounded) == false)
    }

    /// The case this was written for, with the numbers Xcode actually produced
    /// on a 1728-point-wide screen: a 25% column is 432, and Xcode does not go
    /// below 600.
    @Test("A width the app refuses to honour is worth mentioning")
    func aClampedWidthIsReported() {
        let clamped = CGRect(x: 4, y: 37, width: 600, height: 534)

        #expect(AXWindow.differs(asked: asked, applied: clamped))
    }

    @Test("So is a window that ended up somewhere else")
    func aMovedWindowIsReported() {
        let moved = CGRect(x: 186, y: 134, width: 424, height: 534)

        #expect(AXWindow.differs(asked: asked, applied: moved))
    }
}
