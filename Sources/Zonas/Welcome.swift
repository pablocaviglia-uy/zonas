import AppKit

/// Everything the first-launch window knows that does not need a window.
///
/// It is separate from `WelcomeController` for the same reason `EditorDocument`
/// is separate from `EditorController`: what is decided here — whether to open
/// at all, which of the three states the permission is in, and where the menu
/// bar icon ended up — is the part that can be wrong, and the part a test can
/// hold still. The AppKit half is drawing.
enum Welcome {

    // MARK: - Whether to open

    /// The flag records **that the user closed the window**, not that the app
    /// showed it.
    ///
    /// The difference matters exactly once, and it is the case that would
    /// otherwise strand somebody. The window is the only face this app has, so
    /// anything that ends the process before the user has finished with it — a
    /// crash, a `pkill`, closing the session, quitting from the menu to go and
    /// read something — must leave first launch still owed. Writing the flag
    /// when the window *appears* would spend it on an event the user did not
    /// take part in, and the second launch would be the grey icon and the
    /// silence this whole window exists to prevent.
    static let dismissedKey = "welcomeDismissed"

    /// `UserDefaults` and not the layout file: Rule 3. "I have read the
    /// welcome" is this machine's business and would be noise in a file whose
    /// whole claim is that it belongs in your dotfiles repo.
    static func shouldOpen(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: dismissedKey)
    }

    static func dismiss(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedKey)
    }

    // MARK: - The permission, in three states rather than two

    /// What the app can actually do right now.
    ///
    /// **Three states and not two**, which is the one thing no comparable app
    /// does and the reason two of them have long issue threads. "Not granted"
    /// and "granted and still not working" send the user to opposite ends of
    /// the machine, and an app that shows one dimmed icon for both is telling
    /// somebody to go and flip a switch that is already on.
    ///
    /// `AppDelegate` can tell them apart and always could: `startMonitor()`
    /// asks `AXIsProcessTrusted()` and *then* asks the event tap whether it came
    /// up, and `waitForPermission()` keeps retrying precisely because TCC can
    /// flip the bit an instant before the tap subsystem honours it. Until now
    /// both answers arrived here as `setActive(false)`.
    enum Readiness: Equatable {
        /// macOS has not been told to trust us.
        case denied
        /// It has, and the event tap still did not come up.
        case grantedButDeaf
        /// The tap is live. This is the only state in which Zonas does anything.
        case working

        /// What `AppDelegate` knows at the two moments it finds out.
        init(trusted: Bool, tapIsLive: Bool) {
            switch (trusted, tapIsLive) {
            case (false, _): self = .denied
            case (true, false): self = .grantedButDeaf
            case (true, true): self = .working
            }
        }

        var headline: String {
            switch self {
            case .denied: return "Zonas cannot move windows yet"
            case .grantedButDeaf: return "The permission is on, and the drag is not arriving"
            case .working: return "Zonas is ready"
            }
        }

        var detail: String {
            switch self {
            case .denied:
                return "Moving another application's window needs the Accessibility "
                     + "permission, and only you can grant it. Nothing is read or sent "
                     + "anywhere: Zonas watches for a drag and writes back a position."
            case .grantedButDeaf:
                // PLAN §2, which cost an afternoon to find and is the single most
                // useful thing this project knows. The permission is granted to a
                // *signature*, and turning the switch off and on again keeps the
                // old one — measured, twice, both denied. Only − and + rewrite it.
                return "macOS reports the permission as granted and the drag still does "
                     + "not reach Zonas. Remove Zonas from the Accessibility list with − "
                     + "and add it again with +; switching it off and on again does not "
                     + "clear this."
            case .working:
                return "The menu bar icon is no longer dimmed, which is the only "
                     + "confirmation there is."
            }
        }

        /// The button, when there is something for it to do.
        ///
        /// `.working` has none on purpose. A button that reopens a panel to show
        /// you a switch that is already in the right position is an invitation
        /// to break something that works.
        var action: String? {
            switch self {
            case .denied: return "Grant Access…"
            case .grantedButDeaf: return "Open Accessibility Settings…"
            case .working: return nil
            }
        }

        var isWorking: Bool { self == .working }
    }

    // MARK: - The gesture, in the keys the file actually names

    /// How the gesture reads, with the keys taken from the layout rather than
    /// from this sentence.
    ///
    /// Hardcoding ⇧ here would be a lie for anybody who changed `modifier`, and
    /// it is the kind of lie nobody ever files: the person it is wrong for
    /// concludes the app is broken and stops. There is a test that changes the
    /// modifier and reads these back.
    static func gesture(_ layout: Layout) -> String {
        let key = layout.modifier.symbol
        return "Hold \(key) and drag any window. The zones light up, and letting go of "
             + "\(key) drops the window into the one under the cursor."
    }

    /// The second line, which exists only when the file names a span key.
    ///
    /// **The order is the instruction, not decoration.** On macOS ⌃ held while
    /// the mouse button goes down *is* the secondary click, so pressing it first
    /// turns the whole gesture into a right-click and nothing happens at all.
    /// MacsyZones has an issue asking for the order to be made irrelevant, filed
    /// by somebody who was never told there was an order.
    static func spanning(_ layout: Layout) -> String? {
        guard let span = layout.span else { return nil }
        return "Start the drag first and then add \(span.symbol), and the zones you cross "
             + "are gathered instead of chosen — the window is given all of them at once."
    }

    /// The way out, which the drag overlay has and nothing tells you about.
    ///
    /// Spelled out rather than written ⎋, which is what the README does and what
    /// the rest of this app does for ⇧ and ⌃. Those two are printed on the
    /// keycap; U+238B is not — it is a broken circle with an arrow through it,
    /// and drawn at 13 points in the system font it reads as a loading spinner.
    /// Seen on screen, which is the only way this was ever going to be noticed.
    static let escape = "Press Escape at any point to leave the window where it was."

    // MARK: - Where the icon ended up

    /// A schematic of this machine's menu bar, in fractions of its width.
    ///
    /// Fractions rather than points because the thing being drawn is 520 points
    /// wide and the thing being described is 1728, and because that makes it a
    /// pure function of four rectangles — which is what lets a test state the
    /// answer instead of asking the machine it is running on. `Coords.cgToView`
    /// exists for the same reason.
    struct Sketch: Equatable {

        /// The notch, when the screen has one. Measured on this machine: 185
        /// points wide, spanning x ∈ [771, 956] of a 1728-point screen.
        let notch: ClosedRange<Double>?

        /// Where macOS put Zonas' own icon.
        let icon: ClosedRange<Double>?

        /// Whether macOS is drawing that icon anywhere a person can see it.
        ///
        /// Not derivable from `icon`, which is the whole trap: an item crowded
        /// off the bar still reports a perfectly plausible on-screen frame.
        /// Measured — six items reporting frames between x=526 and x=906, all
        /// left of the notch, none of them drawn. See
        /// `NSStatusItem.isHiddenFromUser`.
        let iconIsVisible: Bool

        var hasNotch: Bool { notch != nil }

        /// - Parameters:
        ///   - bar: the screen's full frame, which is the width the menu bar spans.
        ///   - notch: `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`
        ///     leave a gap between them; this is that gap, in the same
        ///     coordinates as `bar`.
        ///   - icon: the status item button's window frame.
        static func of(bar: CGRect, notch: CGRect?, icon: CGRect?, iconIsVisible: Bool) -> Sketch {
            // A zero-width screen is not a thing, but it arrives here as a
            // division and would take the whole window with it.
            guard bar.width > 0 else {
                return Sketch(notch: nil, icon: nil, iconIsVisible: iconIsVisible)
            }
            func span(_ rect: CGRect?) -> ClosedRange<Double>? {
                guard let rect, rect.width > 0 else { return nil }
                // Clamped rather than dropped: an icon that has been pushed off
                // the left-hand end reports a negative origin, and drawing it
                // pinned to the edge says "there, and it did not fit" better
                // than drawing nothing at all.
                let lower = min(max((rect.minX - bar.minX) / bar.width, 0), 1)
                let upper = min(max((rect.maxX - bar.minX) / bar.width, 0), 1)
                // Sorted rather than trusted, and it is not defensive padding.
                // `ClosedRange` **traps** on inverted bounds, so these two lines
                // are one edit away from crashing the app instead of drawing the
                // sketch slightly wrong — which is what happened: dropping the
                // `bar.minX` from the first line alone, to see whether a test
                // would catch it, took the whole suite down with
                // `Range requires lowerBound <= upperBound` rather than failing
                // the test that was watching for it. A wrong picture is a shrug;
                // a trap in the window that exists to rescue a confused user is
                // not.
                return min(lower, upper)...max(lower, upper)
            }
            return Sketch(notch: span(notch), icon: span(icon), iconIsVisible: iconIsVisible)
        }
    }
}

// MARK: - Asking macOS whether it is drawing our icon

extension NSStatusItem {

    /// True when macOS is not drawing this item anywhere the user can see.
    ///
    /// **`occlusionState` is the only thing that tells the truth**, and finding
    /// that out took measuring every other candidate against a screenshot with
    /// coloured swatches in the items. `window.isVisible` is *always* true, even
    /// for an item explicitly hidden. `button.isHidden` is always false.
    /// `isVisible` reports only what we ourselves set — it answered yes for all
    /// 26 items that had been crowded off the bar. And `button.window?.frame`,
    /// the obvious candidate, is worse than useless: crowded-out items get
    /// plausible on-screen frames marching leftward (906, 830, 754, 678, …)
    /// while nothing at all is drawn. Counting the swatches in the screenshot
    /// found two icons; occlusion said two; the frames said eight.
    ///
    /// The finding that makes this worth having at all: macOS never wraps status
    /// items around to the left of the notch. The first item that would cross
    /// into it is dropped and so is every item after it — and **a new item is
    /// the one at the end of the queue**, so an app installed onto a full menu
    /// bar is precisely the one that disappears. That is Zonas' first launch,
    /// not an edge case.
    ///
    /// Two things it gets wrong, both mitigated by *when* it is asked:
    ///
    /// - For about 80 ms after the item is created it says hidden for an icon
    ///   that is plainly there (first correct reading at 54–79 ms over five
    ///   runs), and a transition takes ~0.75 s to settle. Never ask it
    ///   synchronously at launch.
    /// - A menu bar hidden for an unrelated reason — a full-screen app, or
    ///   "Automatically hide and show the menu bar" — would make every item
    ///   report the same thing and this cry wolf. The welcome window asks while
    ///   it is itself on screen and frontmost, which is the one moment that
    ///   cannot be true.
    var isHiddenFromUser: Bool {
        // Told apart from macOS hiding it, because the two have opposite
        // remedies and only one of them is the user's problem.
        guard isVisible else { return true }
        guard let window = button?.window else { return true }
        return !window.occlusionState.contains(.visible)
    }
}

extension NSScreen {

    /// The notch, in this screen's own (Cocoa) coordinates, or `nil`.
    ///
    /// macOS describes it by its absence: `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea` are the two runs of menu bar either side of it,
    /// and the notch is the gap between them. Measured here: left ends at 771,
    /// right starts at 956, so the notch is 185 points wide.
    ///
    /// `safeAreaInsets.top != 0` answers the yes/no question just as well but
    /// hands back no geometry, and the geometry is the point — the sketch has to
    /// draw it where it is.
    var notchFrame: CGRect? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return nil
        }
        return CGRect(x: left.maxX, y: left.minY,
                      width: right.minX - left.maxX, height: left.height)
    }
}
