import AppKit

/// macOS has two screen coordinate systems and they do not agree.
///
/// - **Cocoa** (`NSScreen`, `NSWindow`): origin at the bottom-left of the main
///   screen, Y grows upwards.
/// - **CoreGraphics / Accessibility** (`CGEvent.location`, `kAXPositionAttribute`):
///   origin at the top-left of the main screen, Y grows downwards.
///
/// With a single monitor the difference is barely noticeable. With two of
/// different heights, or with the secondary one sitting above the main one, it
/// is the number one source of bugs in this kind of app: the window ends up
/// mirrored vertically.
///
/// There is a single rule here: **every internal calculation lives in CG
/// coordinates**, because that is the language the mouse and the Accessibility
/// API speak. The conversion to Cocoa happens only when placing the overlay
/// window.
enum Coords {

    /// Top edge of the global desktop according to Cocoa. It is the pivot of
    /// the conversion: the "ceiling" the Y coordinate is mirrored against.
    static var primaryMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// Mirrors a rectangle between the two systems.
    ///
    /// The operation is its own inverse —mirroring twice gives back the
    /// original—, so a single function covers both directions. It is exposed
    /// under two names so that the call site reads as which way it is going.
    private static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryMaxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func cocoaToCG(_ rect: CGRect) -> CGRect { flip(rect) }
    static func cgToCocoa(_ rect: CGRect) -> CGRect { flip(rect) }
}

extension NSScreen {

    /// The display this screen is showing on.
    ///
    /// **`NSScreen` instances are not identity.** AppKit replaces them wholesale
    /// whenever displays are reconfigured — plugging a monitor in, waking from
    /// sleep, changing the resolution — so anything keyed by one accumulates
    /// entries that will never be looked up again, and comparing two of them is
    /// comparing objects that may both already be dead.
    ///
    /// The display ID survives all of that, and it is the same number the
    /// Accessibility and CoreGraphics APIs use. Verified present in
    /// `deviceDescription` on this machine, and documented as always being
    /// there.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// The screen's full frame in CG coordinates.
    var cgFrame: CGRect { Coords.cocoaToCG(frame) }

    /// The area that is actually usable, in CG coordinates: it discounts the
    /// menu bar, the Dock and —on the machines that have one— the notch.
    var cgVisibleFrame: CGRect { Coords.cocoaToCG(visibleFrame) }

    /// The screen containing a point given in CG coordinates.
    ///
    /// If the point falls outside every screen —which can happen while dragging
    /// between monitors— the main one is returned instead of `nil`, so the
    /// caller does not have to handle a case that adds nothing.
    static func containing(cgPoint point: CGPoint) -> NSScreen? {
        screens.first { $0.cgFrame.contains(point) } ?? screens.first
    }
}
