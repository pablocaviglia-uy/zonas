import AppKit

/// The zone editor: one window per screen, over the real desktop, at 1:1.
///
/// This is the first of five pieces and it deliberately offers no editing at
/// all. Everything hard about the editor is in getting the window up and
/// leaving it correct — the coordinate space, the levels, the Spaces, the
/// keyboard, and the fact that the app's own event tap has to be told to be
/// quiet — and none of that is easier to debug with a drag gesture on top of
/// it.
///
/// **Full screen at 1:1 rather than a scaled panel**, which is §5's decision
/// and the reason there is no arithmetic in here: one point in this window is
/// one point of the space the zones live in, so the fraction→point conversion
/// is the same `Zone.rect(in:)` the snap already uses. A scaled editor on a
/// 3.56∶1 monitor does not merely look different from the result, it lies about
/// it.
///
/// **A translucent fill and not a screenshot.** Capturing the desktop to dim it
/// would need Screen Recording permission, and asking for a second system
/// permission — the one people associate with spyware — to draw a grey
/// rectangle would cost this app more users than the editor could ever win.
final class EditorController {

    /// One window per **display**, for the reason `OverlayController` documents:
    /// `NSScreen` instances are replaced wholesale on every reconfiguration.
    private var windows: [CGDirectDisplayID: EditorWindow] = [:]
    private var screenObserver: NSObjectProtocol?

    private(set) var isOpen = false

    /// Fires on open and on close. It exists because "the editor is up" is not
    /// only the editor's business: the drag monitor has to stop listening while
    /// it is, and putting that rule inside this class would hide the app's one
    /// piece of cross-component policy inside the newest component.
    var onVisibilityChange: ((Bool) -> Void)?

    // MARK: - Opening and closing

    func open() {
        // Asking twice should bring it forward, not build a second set of
        // windows over the first — which is invisible until you close it once
        // and the screen is still dimmed.
        guard !isOpen else { return activate() }

        build()
        guard !windows.isEmpty else {
            Log.write("editor: not a single screen reported a display ID, not opening")
            return
        }

        isOpen = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuild() }

        onVisibilityChange?(true)
        activate()
        Log.write("editor: open on \(windows.count) screen(s)")
    }

    func close() {
        guard isOpen else { return }
        tearDown()
        isOpen = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        onVisibilityChange?(false)
        Log.write("editor: closed")
    }

    /// The file changed while the editor was open.
    ///
    /// Redrawing costs five lines and keeps the editor's claim — that it shows
    /// the zones you have — true rather than true-when-it-opened. It is free
    /// right now precisely because this piece has nothing of its own to lose: it
    /// holds no edit, so there is nothing for an external change to conflict
    /// with. The piece that introduces the write path is the one that has to
    /// answer that question properly, with the banner §5 describes.
    func refresh() {
        guard isOpen else { return }
        let layout = LayoutStore.shared.layout
        let problem = LayoutStore.shared.problem
        for window in windows.values { window.editorView?.show(layout, problem: problem) }
    }

    // MARK: - Windows

    private func build() {
        let layout = LayoutStore.shared.layout
        let problem = LayoutStore.shared.problem

        for screen in NSScreen.screens {
            guard let display = screen.displayID else {
                Log.write("editor: a screen has no NSScreenNumber, skipping it")
                continue
            }
            let window = EditorWindow(screen: screen)
            window.onCancel = { [weak self] in self?.close() }
            window.editorView?.show(layout, problem: problem)
            windows[display] = window
        }
    }

    private func tearDown() {
        for window in windows.values {
            // The closure holds this controller, and this controller holds the
            // window. It is broken here rather than by hoping `orderOut` is the
            // last thing that ever touches it.
            window.onCancel = nil
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    /// Displays came or went while the editor was up.
    ///
    /// Rebuilding wholesale rather than reconciling: this is the one moment when
    /// `visibleFrame` changes on screens that did *not* come or go — plugging in
    /// a monitor moves the Dock, and the Dock is the bottom of every zone on
    /// whichever screen it lands on.
    private func rebuild() {
        guard isOpen else { return }
        Log.write("editor: the screens changed, rebuilding")
        tearDown()
        build()
        guard !windows.isEmpty else { return close() }
        activate()
    }

    /// Brings the windows forward and gives one of them the keyboard.
    ///
    /// `NSApp.activate()` is not optional. An `.accessory` app has no Dock icon
    /// and no application menu, so nothing else in the system is ever going to
    /// decide these windows should have focus, and without focus Escape does
    /// nothing. Switching to `.regular` to get it for free is the trade that
    /// looks tempting and is not: it puts a Dock icon on a menu bar utility for
    /// as long as the app runs, not for as long as the editor is open.
    private func activate() {
        NSApp.activate()
        windows.values.forEach { $0.orderFrontRegardless() }

        // Key goes to the screen the cursor is on, because that is the screen
        // you are looking at. `NSEvent.mouseLocation` is in Cocoa coordinates,
        // which is why this compares against `frame` and not `cgFrame`.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let key = screen?.displayID.flatMap { windows[$0] } ?? windows.values.first
        key?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The window

/// The editor's window on one screen.
final class EditorWindow: NSWindow {

    /// Escape, and the Done button, and anything else that means "get me out of
    /// here". It closes **every** screen's window, not this one, which is why it
    /// is a closure back to the controller and not a method here.
    var onCancel: (() -> Void)?

    var editorView: EditorView? { contentView as? EditorView }

    init(screen: NSScreen) {
        // Exactly `visibleFrame`, which is what makes the whole thing 1:1:
        // zones are fractions of the usable area, and this window *is* the
        // usable area. It also means the menu bar, the Dock and the notch are
        // discounted without a line of code, because `visibleFrame` already did
        // it.
        super.init(contentRect: screen.visibleFrame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Created in code and owned by a dictionary, so ARC is what should free
        // it. Left at its default, any stray `close()` would over-release.
        isReleasedWhenClosed = false

        // `.floating` (3) and not the drag overlay's `.popUpMenu` (101), which
        // is the difference between the two windows' jobs. The overlay has to
        // cover the window being moved. The editor has to sit *below the menu
        // bar*, so that the strip you are excluding from every zone is visible
        // above the thing that excludes it.
        level = .floating

        // Deliberately no `.canJoinAllSpaces`, which the drag overlay does use:
        // a drag can cross a Space, an editing session cannot. Following you
        // from Space to Space would mean a full-screen scrim on a desktop you
        // switched to in order to look at something else.
        collectionBehavior = [.fullScreenAuxiliary]

        contentView = EditorView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size),
                                 area: screen.cgVisibleFrame)
    }

    /// A borderless window answers `false` here and then never receives a key
    /// event at all — no Escape, no anything. This is the single line between
    /// "there is a window on screen" and "there is a window you can talk to".
    override var canBecomeKey: Bool { true }

    /// 53 is Escape. It is read from the key code and not from the characters,
    /// because the characters depend on the keyboard layout and this key does
    /// not.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { return super.keyDown(with: event) }
        cancel(nil)
    }

    /// Both ways out arrive here, and both arrive **while AppKit is delivering
    /// an event to this window or to a button inside it**. Closing releases the
    /// last reference to the window, so doing it synchronously means
    /// deallocating the object that is in the middle of its own `keyDown` — a
    /// crash that depends on the autorelease pool and therefore shows up on
    /// somebody else's machine rather than on this one. One run loop turn is
    /// enough to be out of the frame that owns it.
    @objc func cancel(_ sender: Any?) {
        // Captured by value: `close()` clears the property on the way past, and
        // reading it from the block would then find nothing to call.
        DispatchQueue.main.async { [onCancel] in onCancel?() }
    }
}

// MARK: - The drawing

/// The dimmed desktop, the zones on top of it, and the bar.
final class EditorView: NSView {

    struct Box {
        let rect: CGRect
        let name: String
    }

    /// §5 says "the real desktop dimmed to 40%", and this is the reading it
    /// takes: the desktop is left at 40% of itself, so the fill over it is 60%
    /// black. Dark enough that a white outline reads at a glance, light enough
    /// that you can still see which window is where — which matters, because
    /// the point of editing over the real desktop instead of a grey panel is
    /// seeing what your zones would do to the windows you actually have open.
    private static let desktopBrightness: CGFloat = 0.4

    /// The screen's usable area in CG coordinates. Zones are fractions of this,
    /// and this view covers exactly it — that equality is the 1:1 claim, and
    /// `Coords.cgToView` is where it gets cashed in.
    private let area: CGRect

    private let hud = EditorHUD()
    private var boxes: [Box] = []

    init(frame: NSRect, area: CGRect) {
        self.area = area
        super.init(frame: frame)
        addSubview(hud)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Zonas builds its windows in code") }

    func show(_ layout: Layout, problem: String?) {
        // `viewFrames` draws `frame` and not `rect`, which is the same call the
        // drag overlay makes and for the same reason: the frame is the rectangle
        // a window dropped here is given, gap and margin included. An editor
        // showing a shape no window will ever be given is §3e back again, in the
        // one place where the drawing is not a preview of the product but the
        // product.
        //
        // Hit-testing, when this piece grows any, has to go the other way and
        // ask `rect` — the regions that tile — or every gap becomes a band where
        // clicking selects nothing.
        boxes = layout.viewFrames(in: area).enumerated().map {
            Box(rect: $1, name: layout.zones[$0].name)
        }

        hud.show(title: layout.name, hint: hint(for: layout, problem: problem))
        layOutHUD()
        needsDisplay = true
    }

    private func hint(for layout: Layout, problem: String?) -> String {
        if let problem {
            // Saying which zones these are matters more here than anywhere else
            // in the app. The store keeps the last layout that read cleanly, so
            // the editor is showing something real — just not what is in the
            // file the user is about to go and look at.
            return "⚠︎ \(problem) — showing the last layout that read cleanly"
        }
        let zones = layout.zones.count == 1 ? "1 zone" : "\(layout.zones.count) zones"
        // The usable area, not the display's resolution, because that is what
        // the fractions are fractions of — and the difference between the two
        // numbers is the menu bar and the Dock, which is exactly the thing this
        // window is sitting below in order to show.
        return "\(zones) · \(Int(area.width)) × \(Int(area.height)) usable · ⎋ to close"
    }

    private func layOutHUD() {
        // The bar sizes itself to its text, and the text has just changed. Ask
        // before the layout pass has run and the answer is the size it was one
        // layout name ago.
        hud.layoutSubtreeIfNeeded()
        let size = hud.fittingSize
        hud.frame = NSRect(x: (bounds.width - size.width) / 2,
                           y: 32,
                           width: size.width,
                           height: size.height)
    }

    override func layout() {
        super.layout()
        layOutHUD()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(1 - Self.desktopBrightness).setFill()
        bounds.fill()

        for box in boxes {
            // **An outline and no fill**, which is where the drag overlay and
            // this part company, and it was measured rather than chosen.
            //
            // The overlay fills each zone with white at 8% and that is right
            // there, because the overlay has no scrim under it. Here it does,
            // and a fill over a scrim is additive where the scrim is
            // multiplicative: with white at 10% the desktop came out at
            // 0.36·b + 0.10 instead of 0.4·b. On this laptop's wallpaper that is
            // 0.51 → 0.29 rather than 0.20, and on the ultrawide, whose desktop
            // sits at 0.13, it is 0.15 — **brighter than not dimming at all**.
            //
            // Which is the trap: zones tile the screen, so a per-zone fill is
            // not a highlight, it is a second scrim with the opposite sign, and
            // it undoes the most work exactly where the dimming matters most.
            // The outline and the label are the whole of the information here.
            // The fill comes back when there is something to single out — the
            // zone under the cursor — and then it will be worth what it costs.
            let path = NSBezierPath(roundedRect: box.rect, xRadius: 14, yRadius: 14)
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 2
            path.stroke()

            draw(box)
        }
    }

    private func draw(_ box: Box) {
        let name = NSAttributedString(string: box.name, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        // Points, not fractions, and no rounding games: at 1:1 these are the
        // view's own numbers, so a zone that reads 1280 × 1417 is 1280 × 1417
        // of the screen it is drawn on. It is the cheapest possible check that
        // the coordinate work above is right, and it is on screen every time
        // the editor opens rather than only when somebody runs the tests.
        let size = NSAttributedString(
            string: "\(Int(box.rect.width.rounded())) × \(Int(box.rect.height.rounded()))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ])

        let nameSize = name.size()
        let sizeSize = size.size()
        let block = nameSize.height + 2 + sizeSize.height
        let top = box.rect.midY + block / 2

        name.draw(at: CGPoint(x: box.rect.midX - nameSize.width / 2, y: top - nameSize.height))
        size.draw(at: CGPoint(x: box.rect.midX - sizeSize.width / 2, y: top - block))
    }
}

// MARK: - The bar

/// The floating bar: what layout this is, what is going on, and the way out.
///
/// One per screen and not one on the main screen. On a desk with a 5120-point
/// monitor next to a laptop, a Done button that is on the other screen from the
/// one you are looking at is a Done button you have to go and find.
final class EditorHUD: NSVisualEffectView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init() {
        super.init(frame: .zero)

        // `.behindWindow` samples the real desktop rather than the scrim this
        // sits on, so the bar comes out brighter than everything around it
        // instead of a slightly different grey.
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Pinned dark. The scrim underneath is 60% black whatever the system
        // theme is, and in Light Mode `labelColor` would come out near-black on
        // it.
        appearance = NSAppearance(named: .darkAqua)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        doneButton.bezelStyle = .rounded

        let text = NSStackView(views: [titleLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [text, doneButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 24
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Zonas builds its windows in code") }

    /// The button is wired here rather than at init because its target is the
    /// window, and the window does not exist until after its content view does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        doneButton.target = window
        doneButton.action = #selector(EditorWindow.cancel(_:))
    }

    func show(title: String, hint: String) {
        titleLabel.stringValue = title
        hintLabel.stringValue = hint
        needsLayout = true
    }
}
