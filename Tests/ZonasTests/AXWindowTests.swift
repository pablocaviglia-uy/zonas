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

/// The subrole rule, which is the one part of "is this a window Zonas may
/// move" that can be asked without a window belonging to another process.
///
/// The two halves are kept apart on purpose. The first is a list of subroles
/// that **must keep working**, and every entry is a real window somebody drags:
/// if a future tightening of this rule breaks one, this is where it says so.
/// The second is the two the rule actually exists to stop.
@Suite("Which windows belong to the system rather than to an app")
struct WindowSubroleTests {

    @Test("A standard window is an app's own", arguments: ["AXStandardWindow"])
    func theOrdinaryCase(subrole: String) {
        #expect(AXWindow.isTheSystemsOwn(subrole: subrole) == false)
    }

    /// The list that killed the obvious rule. Accepting only `AXStandardWindow`
    /// would have refused every one of these, and each is a window a person
    /// drags around: Xcode's Settings and IntelliJ's Open dialog are `AXDialog`,
    /// Steam and Keynote's presentation mode and Firefox's own full screen are
    /// `AXUnknown`, Transmission's Inspector is `AXFloatingWindow`, and Finder's
    /// Quick Look panel answers with a subrole that is in no header at all.
    @Test("A named subrole is not by itself the system's",
          arguments: ["AXDialog", "AXUnknown", "AXFloatingWindow", "Quick Look", "AXDocumentWindow"])
    func namedButStillAnApps(subrole: String) {
        #expect(AXWindow.isTheSystemsOwn(subrole: subrole) == false)
    }

    /// Notification Center's full-screen shield is `AXSystemDialog` on this
    /// machine, measured. Nobody drags one of these into a zone.
    @Test("The system's own dialogs and panels are refused",
          arguments: ["AXSystemDialog", "AXSystemFloatingWindow"])
    func theSystemsOwn(subrole: String) {
        #expect(AXWindow.isTheSystemsOwn(subrole: subrole))
    }
}
