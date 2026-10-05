import ApplicationServices

/// ⌥Tab: going through windows one at a time, where ⌘Tab goes through
/// applications.
///
/// Not to be confused with `Switcher`, which is about *where* macOS's own ⌘Tab
/// opens. This is a second switcher, and it exists because ⌘Tab cannot reach
/// the thing it was asked for: with two Chrome windows, two Android Studio
/// projects or two copies of Claude open, ⌘Tab stops at the application and
/// leaves you to find the window. Here each window is a stop of its own.
///
/// This half decides which windows are on the list, in what order, and which
/// one a press lands on. It has no system calls in it, which is what makes it
/// testable; `WindowSwitcherController` is the half that reads the windows,
/// listens to the keys and brings the chosen one forward.
enum WindowSwitcher {

    /// A window as the WindowServer lists it: `CGWindowListCopyWindowInfo`,
    /// front to back.
    ///
    /// **This is the only place the order comes from.** The Accessibility API
    /// lists each application's windows on their own, and there is no question
    /// it can be asked about how Chrome's windows sit among Teams'. The
    /// WindowServer's list is the stacking order of the whole screen, which is
    /// also the order you last used them in: the window you were in a moment
    /// ago is the one right behind this one. That is the order ⌥Tab has to
    /// walk, so that one press goes back to where you were.
    ///
    /// None of these fields needs the Screen Recording permission. The title
    /// would, and is not read here — see Rule 12.
    struct Listed: Equatable {
        var id: CGWindowID
        var pid: pid_t
        var layer: Int
        var alpha: Double
        var bounds: CGRect
    }

    /// A window as its application describes it through Accessibility.
    ///
    /// Generic over the handle so the tests can hold a string where the app
    /// holds an `AXWindow`.
    struct Window<Handle> {
        var handle: Handle
        /// The WindowServer's number for it, which is what joins it to a
        /// `Listed`. `nil` when the application would not say.
        var id: CGWindowID?
        var pid: pid_t
        var subrole: String?
        var title: String?
        var isMinimized = false
        /// Whether its *application* is hidden — ⌘H hides every window at once.
        var isHidden = false
    }

    private struct Identity: Hashable {
        let window: CGWindowID
        let owner: pid_t
    }

    /// One stop on the list.
    struct Entry<Handle> {
        var window: Window<Handle>
        /// Where it is on screen, in CG coordinates, or `nil` for a window that
        /// is not on screen at all: minimized, or its application hidden.
        var bounds: CGRect?
    }

    /// The list ⌥Tab walks, and the windows it leaves out.
    ///
    /// **Joined by window number, and never by position.** The obvious way to
    /// match an Accessibility window to its entry in the WindowServer's list is
    /// the frame, since both report one, and in this app in particular it is
    /// wrong: two windows snapped into the same zone have *the same frame*, to
    /// the point. Matching on it would put them in whichever order the
    /// dictionary happened to iterate — and the pair of windows most likely to
    /// be sitting on top of each other in one zone is exactly the pair somebody
    /// is trying to alternate between.
    ///
    /// On screen first, in the WindowServer's order. Then the windows that are
    /// not on screen but can be brought back — minimized, or belonging to a
    /// hidden application — in the order they were read, because nothing says
    /// when each was last used. A window that is neither is on another Space,
    /// and is not on the list: bringing it forward means sliding the whole
    /// desktop sideways, which is a different gesture from switching windows.
    ///
    /// **What is reported as left out is only what is on screen.** The
    /// question that list answers is "I can see that window, why is it not
    /// here", and the first run of this reported Finder's desktop on every
    /// press: Accessibility lists it as one of Finder's windows, with no
    /// subrole, no title and no number, and nobody has ever looked for it.
    static func entries<Handle>(listed: [Listed],
                                windows: [Window<Handle>],
                                own: pid_t) -> (entries: [Entry<Handle>], leftOut: [Window<Handle>]) {
        // Layer 0 is where applications' ordinary windows live; everything above
        // it is menus, the Dock, overlays and the menu bar. A window at alpha 0
        // is on screen only in the sense that it has not been closed.
        let visible = listed.filter { $0.layer == 0 && $0.alpha > 0 && $0.pid != own }
        let seen = Set(visible.map(\.id))

        let theirs = windows.filter { $0.pid != own }
        let candidates = theirs.filter { isSwitchable(subrole: $0.subrole, title: $0.title) }
        let leftOut = theirs.filter { window in
            !isSwitchable(subrole: window.subrole, title: window.title)
                && window.id.map(seen.contains) == true
        }

        // A cache must not lend an old owner's handle to a reused window ID.
        var byID: [Identity: Int] = [:]
        for (index, window) in candidates.enumerated() {
            guard let id = window.id else { continue }
            let identity = Identity(window: id, owner: window.pid)
            guard byID[identity] == nil else { continue }
            byID[identity] = index
        }

        var taken = Set<Int>()
        var entries: [Entry<Handle>] = []
        for window in visible {
            guard let index = byID[Identity(window: window.id, owner: window.pid)],
                  taken.insert(index).inserted else { continue }
            entries.append(Entry(window: candidates[index], bounds: window.bounds))
        }
        for (index, window) in candidates.enumerated()
        where !taken.contains(index) && (window.isMinimized || window.isHidden) {
            entries.append(Entry(window: window, bounds: nil))
        }
        return (entries, leftOut)
    }

    /// Whether a window is somewhere anybody would want to switch *to*.
    ///
    /// **A standard window always is. Anything else has to have a title.** The
    /// impostor this is for is the Android emulator's floating toolbar: a 54 ×
    /// 506 strip beside the emulator that says it is an `AXDialog` and has no
    /// title, and that would otherwise be a stop of its own on every ⌥Tab.
    /// `AXWindow.refusal` cannot refuse it — its own documentation says no rule
    /// worth shipping could, because it looks like Transmission's Inspector —
    /// and it is right not to, for the drag: a window that will not move is
    /// the failure that stage exists to prevent.
    ///
    /// The trade is the other way round here, and that is why this is a rule
    /// of its own rather than a reuse of that one. Leaving a window off this
    /// list costs a trip through ⌘Tab; putting a toolbar on it costs a stop on
    /// every press. A real window with no title and no standard subrole is the
    /// rare case, and the one this gives up.
    ///
    /// The system's own panels are left out either way, for the reason
    /// `AXWindow.isTheSystemsOwn` gives.
    static func isSwitchable(subrole: String?, title: String?) -> Bool {
        if let subrole, AXWindow.isTheSystemsOwn(subrole: subrole) { return false }
        if subrole == kAXStandardWindowSubrole as String { return true }
        return !(title ?? "").isEmpty
    }

    // MARK: - Where a press lands

    /// Which entry is chosen, and where the next press takes it.
    ///
    /// The first press chooses the **second** entry, because the first is the
    /// window you are already in. That is what makes the most common use of
    /// the key — tap it once, go back to where you were — a single tap. Going
    /// backwards starts from the far end, the way ⌘⇧Tab does.
    struct Cycle: Equatable {
        let count: Int
        private(set) var index: Int

        /// `nil` for an empty list, which has nothing to choose.
        init?(count: Int, backwards: Bool) {
            guard count > 0 else { return nil }
            self.count = count
            index = backwards ? count - 1 : min(1, count - 1)
        }

        /// One step either way, wrapping at both ends.
        mutating func step(_ delta: Int) {
            index = ((index + delta) % count + count) % count
        }

        /// The cycle once the window at `position` has been closed, or `nil`
        /// when it was the last one.
        ///
        /// The choice stays on the same window when another one went. When the
        /// chosen one went, the choice falls on the window that took its place
        /// — the next one, which is where the eye already is — or on the one
        /// before it, when it was the last.
        func removing(_ position: Int) -> Cycle? {
            guard count > 1 else { return nil }
            guard (0 ..< count).contains(position) else { return self }
            let chosen = position < index ? index - 1 : min(index, count - 2)
            return Cycle(count: count - 1, chosen: chosen)
        }

        private init(count: Int, chosen: Int) {
            self.count = count
            index = chosen
        }
    }

    // MARK: - What the list says about a window

    /// A window's title with its application's name taken off the end.
    ///
    /// Browsers and chat applications sign every title — "Opciones Mixamo -
    /// Google Chrome", "Chat | Daily Stand Up | Microsoft Teams" — and the
    /// application is already on screen as its icon, so the signature is the
    /// part of the title that tells two windows apart least. A window with no
    /// title is called by its application's name.
    static func title(_ raw: String?, application: String) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return application
        }
        for separator in [" - ", " – ", " — ", " | "] {
            let signature = separator + application
            if raw.count > signature.count, raw.hasSuffix(signature) {
                return String(raw.dropLast(signature.count))
            }
        }
        return raw
    }

    /// Where a window sits, in the layout's terms.
    enum Place: Equatable {
        /// Snapped into these zones — one, or several it was spread across
        /// with the span key — by index into `Layout.zones`, in file order.
        case zones([Int])
        case wholeScreen
        /// On screen, and in no zone.
        case floating
    }

    /// Which zones a window fills, if any.
    ///
    /// **Filling them, not being over them.** `Layout.zoneIndex(holding:in:)`
    /// asks which zone the middle of a window is over, which is the right
    /// question for the arrows and the wrong one here: a floating Finder
    /// window whose middle happens to be over "Centro" is not in Centro in any
    /// sense anybody means, and a label saying it is would be wrong about
    /// exactly the kind of window it most needs to describe.
    ///
    /// Four answers, tried in this order:
    ///
    /// - **The whole screen**, when the window is nearly the maximised frame.
    /// - **One zone it nearly is**: four fifths overlap or better, which is a
    ///   snap, and also an application that would not quite shrink to it —
    ///   Chrome stops at 500 points against the laptop's 428-point column,
    ///   and still overlaps it 86%. Asked first so that a zone sitting on top
    ///   of a bigger one, which a file may have, is told apart from it.
    /// - **Several zones it spans**: it covers nine tenths of each, and they
    ///   hold four fifths of it between them — the gaps between the zones
    ///   are the rest.
    /// - **One zone it is too big for**: it covers that zone, and at least half
    ///   of it is inside. WhatsApp stops at 800 points in the same column, so
    ///   only 54% of it is there — but that is where it was put.
    ///
    /// Anything else is floating.
    static func place(of frame: CGRect, in layout: Layout, area: CGRect) -> Place {
        let window = surface(of: frame)
        guard window > 0 else { return .floating }
        if overlap(frame, layout.frame(of: Layout.maximised, in: area)) >= 0.9 { return .wholeScreen }

        let rects = layout.zones.map { layout.frame(of: $0, in: area) }
        let shared = rects.map { surface(of: frame.intersection($0)) }

        let nearest = rects.indices.max { overlap(frame, rects[$0]) < overlap(frame, rects[$1]) }
        if let nearest, overlap(frame, rects[nearest]) >= 0.8 { return .zones([nearest]) }

        let covered = rects.indices.filter { shared[$0] >= 0.9 * surface(of: rects[$0]) }
        if covered.count > 1, covered.reduce(0, { $0 + shared[$1] }) >= 0.8 * window {
            return .zones(covered)
        }
        if let biggest = covered.max(by: { shared[$0] < shared[$1] }), shared[biggest] >= 0.5 * window {
            return .zones([biggest])
        }
        return .floating
    }

    /// Intersection over union: 1 for the same rectangle, 0 for two that do
    /// not touch.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = surface(of: a.intersection(b))
        let union = surface(of: a) + surface(of: b) - shared
        return union > 0 ? shared / union : 0
    }

    private static func surface(of rect: CGRect) -> Double {
        rect.isNull || rect.isEmpty ? 0 : Double(rect.width * rect.height)
    }

    /// A full column such as "Izquierda Arriba" + "Izquierda Abajo" should
    /// read as "Izquierda". The shared words come from the user's own names;
    /// geometry prevents a partial or disconnected selection inheriting them.
    static func zoneLabel(_ zones: [Zone]) -> String {
        let full = zones.map(\.name).joined(separator: " + ")
        guard zones.count > 1 else { return full }

        // Hit regions tile edge to edge; window frames intentionally have gaps.
        // Normalized geometry also keeps the label identical on every display.
        func tiles(_ start: KeyPath<Zone, Double>, _ size: KeyPath<Zone, Double>,
                   across: KeyPath<Zone, Double>, breadth: KeyPath<Zone, Double>) -> Bool {
            let tolerance = 0.000_001
            let first = zones[0]
            guard zones.allSatisfy({
                abs($0[keyPath: across] - first[keyPath: across]) < tolerance
                    && abs($0[keyPath: breadth] - first[keyPath: breadth]) < tolerance
                    && $0[keyPath: size] > 0 && $0[keyPath: breadth] > 0
            }) else { return false }
            var edge = 0.0
            for zone in zones.sorted(by: { $0[keyPath: start] < $1[keyPath: start] }) {
                guard abs(zone[keyPath: start] - edge) < tolerance else { return false }
                edge = zone[keyPath: start] + zone[keyPath: size]
            }
            return abs(edge - 1) < tolerance
        }
        guard tiles(\.y, \.height, across: \.x, breadth: \.width)
                || tiles(\.x, \.width, across: \.y, breadth: \.height) else { return full }

        var shared = zones[0].name.split(whereSeparator: \.isWhitespace)
        for zone in zones.dropFirst() {
            let words = zone.name.split(whereSeparator: \.isWhitespace)
            while !shared.isEmpty && !words.starts(with: shared) { shared.removeLast() }
        }
        return shared.isEmpty ? full : shared.joined(separator: " ")
    }

    // MARK: - How it is laid out

    /// How wide each window's cell in the strip is, and how many are shown.
    struct Strip: Equatable {
        var cell: CGFloat
        var visible: Int
    }

    /// The strip for `count` windows in `room` points.
    ///
    /// Cells shrink to fit, the way ⌘Tab's icons do, down to `narrowest` —
    /// below that an icon stops being recognisable — and past that the strip
    /// scrolls instead, keeping the choice in view with `top(showing:)`.
    static func strip(count: Int, room: CGFloat,
                      widest: CGFloat = 84, narrowest: CGFloat = 56) -> Strip {
        guard count > 0, room > 0 else { return Strip(cell: widest, visible: 0) }
        let cell = min(widest, max(narrowest, (room / CGFloat(count)).rounded(.down)))
        return Strip(cell: cell, visible: min(count, max(1, Int(room / cell))))
    }

    /// A window's size scaled to fit a box, keeping its shape.
    ///
    /// **Not enlarged, unless asked.** In the strip a picture blown up past its
    /// own size is a blur in a panel that had room for it at its proper size,
    /// so the default refuses. The ring is the other case: the picture goes on
    /// the window's own rectangle wherever that is on the desktop, because
    /// landing anywhere else — or at any other size — is a ghost of a window
    /// that is not the one being pointed at. It is blown up there, and what
    /// that costs is measured in §7.
    static func fit(_ size: CGSize, into box: CGSize, enlarging: Bool = false) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        var scale = min(box.width / size.width, box.height / size.height)
        if !enlarging { scale = min(scale, 1) }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// The first row to draw, when there are more windows than fit.
    ///
    /// The list only scrolls when the choice would leave it, and only as far
    /// as it has to. Centring the choice instead would move every row on every
    /// press, and a list that jumps under your eyes is hard to aim at.
    static func top(showing selected: Int, from top: Int, count: Int, capacity: Int) -> Int {
        guard capacity > 0, count > capacity else { return 0 }
        var top = min(max(top, 0), count - capacity)
        if selected < top { top = selected }
        if selected >= top + capacity { top = selected - capacity + 1 }
        return top
    }
}
