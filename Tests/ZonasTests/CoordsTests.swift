import Foundation
import Testing
@testable import Zonas

/// The two screens on the machine this was written on, as CoreGraphics sees
/// them: the ultrawide sitting **above** the laptop, which is the arrangement
/// that makes a mirrored Y produce negative coordinates rather than merely
/// wrong ones.
///
/// The laptop is the primary, so its origin is CG's origin. Everything above it
/// has a negative Y, and that is not a contrivance: it is what
/// `NSScreen.cgVisibleFrame` returns on this desk today.
private let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1080)
private let ultrawide = CGRect(x: 0, y: -1440, width: 5120, height: 1440)

@Suite("Putting a CG rectangle inside a window that covers a screen")
struct CoordsTests {

    /// The claim §5 makes for the editor, and the one the drag overlay has been
    /// relying on since it was written: **one point in the window is one point
    /// of the space the zones live in.** If this ever stops holding, every
    /// number in the editor is a number about a different screen.
    @Test("A zone covering the whole area covers the whole view")
    func theWholeAreaIsTheWholeView() {
        for area in [laptop, ultrawide] {
            #expect(Coords.cgToView(area, filling: area)
                    == CGRect(origin: .zero, size: area.size))
        }
    }

    /// CG counts downwards from the top, the view counts upwards from the
    /// bottom. A zone against the top edge of the screen has to end up against
    /// the top edge of the view, which is the far end of the number line.
    @Test("The top of the screen is the top of the view, not the bottom")
    func theTopStaysTheTop() {
        let topHalf = CGRect(x: 0, y: -1440, width: 5120, height: 720)

        let view = Coords.cgToView(topHalf, filling: ultrawide)

        #expect(view == CGRect(x: 0, y: 720, width: 5120, height: 720))
        #expect(view.maxY == ultrawide.height)   // flush against the top
    }

    @Test("The bottom of the screen is the bottom of the view")
    func theBottomStaysTheBottom() {
        let bottomHalf = CGRect(x: 0, y: -720, width: 5120, height: 720)

        #expect(Coords.cgToView(bottomHalf, filling: ultrawide)
                == CGRect(x: 0, y: 0, width: 5120, height: 720))
    }

    /// X is a translation and Y is a mirror, and it is easy to write one where
    /// the other belongs — the two look identical on a screen whose origin is
    /// the origin, which is the laptop, which is where you test first.
    @Test("A screen that does not start at the origin is subtracted, not mirrored, in X")
    func xIsTranslatedNotMirrored() {
        let offset = CGRect(x: 300, y: 100, width: 1000, height: 500)
        let zone = CGRect(x: 300, y: 100, width: 250, height: 500)

        let view = Coords.cgToView(zone, filling: offset)

        #expect(view.minX == 0)          // left edge of the screen, left edge of the view
        #expect(view.width == 250)
    }

    /// Nothing here scales. §5 chose a full-screen editor over a scaled one
    /// precisely so that this arithmetic would not exist, so a size that comes
    /// out different from the size that went in is the whole design going
    /// quietly wrong.
    @Test("Sizes pass through untouched, wherever the screen is")
    func sizesAreNeverScaled() {
        let zone = CGRect(x: 640, y: -1000, width: 1234.5, height: 678.25)

        for area in [laptop, ultrawide] {
            let view = Coords.cgToView(zone, filling: area)
            #expect(view.width == zone.width)
            #expect(view.height == zone.height)
        }
    }

    /// The conversion is a pure function of its two arguments. It used to flip
    /// against `Coords.primaryMaxY` — the top of the whole desktop — and then
    /// subtract the window's origin, and those two uses of the global cancel.
    /// Keeping the global in would make every one of the tests above a
    /// statement about the machine running them.
    @Test("Two screens' worth of zones convert without consulting the desktop")
    func theAnswerDoesNotDependOnTheDesktop() {
        let onTheLaptop = Coords.cgToView(CGRect(x: 0, y: 0, width: 432, height: 1080),
                                          filling: laptop)
        let onTheUltrawide = Coords.cgToView(CGRect(x: 0, y: -1440, width: 1280, height: 1440),
                                             filling: ultrawide)

        // Both are the leftmost column of their own screen, and both land at the
        // origin of their own view. Which screen is the primary never enters it.
        #expect(onTheLaptop.origin == .zero)
        #expect(onTheUltrawide.origin == .zero)
    }
}
