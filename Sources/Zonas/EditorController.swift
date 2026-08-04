import AppKit

/// The zone editor: one window per screen, over the real desktop, at 1:1.
///
/// The first stretch built the window and offered no editing, because
/// everything hard about an editor is in getting the window up and leaving it
/// correct and none of that is easier to debug with a gesture on top of it. The
/// second adds the primary gesture: **a click splits a zone in two**, at the
/// cursor, with ⇧ rotating the cut.
///
/// **It still does not write.** Splits change `document` and closing throws it
/// away — see `EditorDocument`.
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

    /// What is being edited, for every screen at once.
    ///
    /// The controller owns it and the views are handed copies. `EditorDocument`
    /// is a value type, which is what makes that safe and is most of the reason
    /// it is one: a view can build a *candidate* document to show what a split
    /// would do without any chance of that becoming the real one.
    private var document: EditorDocument?

    /// Set when the file changed underneath a document that has been edited.
    /// See `refresh` — this is the smallest honest version of §5's conflict
    /// banner, and it exists because splitting made it necessary.
    private var fileChangedUnderneath = false

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

        // The document is built once, here, from whatever the store holds. From
        // this moment the editor is working on its own copy — see `refresh` for
        // what happens when the file moves underneath it.
        document = EditorDocument(LayoutStore.shared.layout)
        fileChangedUnderneath = false
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
        if document?.isEdited == true {
            // Worth a line, because until the last stretch this is where an
            // editing session goes: nowhere. Silence would make it look like it
            // had been saved.
            Log.write("editor: closing with \(document?.zones.count ?? 0) zones — "
                      + "nothing is written yet, the file is untouched")
        }
        tearDown()
        document = nil
        isOpen = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        onVisibilityChange?(false)
        Log.write("editor: closed")
    }

    /// The file changed while the editor was open.
    ///
    /// **Once you have split something, the document wins.** Following the file
    /// was free in the first stretch because the editor held nothing of its own;
    /// now it does, and replacing an edited document with a reload would throw
    /// away work in response to something happening on another screen.
    ///
    /// So: an untouched editor keeps following the file, which is the live
    /// reload this whole project is about. An edited one stops, and says so in
    /// the bar rather than diverging quietly. That is the smallest honest
    /// version of §5's conflict banner, and stretch 2 is what made it necessary
    /// rather than optional — the full thing, with a way to take the file's
    /// side, belongs with the write path.
    func refresh() {
        guard isOpen, let current = document else { return }

        if current.isEdited {
            fileChangedUnderneath = true
        } else {
            document = EditorDocument(LayoutStore.shared.layout)
        }
        render()
    }

    // MARK: - Windows

    private func build() {
        for screen in NSScreen.screens {
            guard let display = screen.displayID else {
                Log.write("editor: a screen has no NSScreenNumber, skipping it")
                continue
            }
            let window = EditorWindow(screen: screen)
            window.onCancel = { [weak self] in self?.close() }
            window.onUndo = { [weak self] in self?.undo() }
            window.onSplit = { [weak self] rid, fraction, cut, minimum in
                self?.split(rid: rid, at: fraction, cut, minimum: minimum)
            }
            windows[display] = window
        }
        render()
    }

    private func tearDown() {
        for window in windows.values {
            // The closures hold this controller, and this controller holds the
            // window. They are broken here rather than by hoping `orderOut` is
            // the last thing that ever touches it.
            window.onCancel = nil
            window.onUndo = nil
            window.onSplit = nil
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - Editing

    /// Every screen draws the same document, so every screen is redrawn.
    private func render() {
        guard let document else { return }
        let note = fileChangedUnderneath
            ? "⚠︎ the file changed while you were editing — this is your version"
            : LayoutStore.shared.problem.map { "⚠︎ \($0) — showing the last layout that read cleanly" }
        for window in windows.values {
            window.editorView?.show(document, note: note)
        }
    }

    private func split(rid: Int, at fraction: Double, _ cut: Cut, minimum: Double) {
        guard var document else { return }
        guard document.split(rid: rid, at: fraction, cut, minimum: minimum) else { return }
        self.document = document
        Log.write("editor: split into \(document.zones.count) zones")
        render()
    }

    private func undo() {
        guard var document, document.undo() else { return }
        self.document = document

        // Undoing back to the start makes the document untouched again, and an
        // untouched document is one that follows the file. **Following it means
        // re-reading it here**, not at the next save: the file may well have
        // moved while the document was refusing to listen, and clearing the
        // warning while still showing the old version would be the same lie the
        // warning was put there to avoid.
        if !document.isEdited {
            fileChangedUnderneath = false
            self.document = EditorDocument(LayoutStore.shared.layout)
        }
        render()
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

    /// Everything that changes the document goes back up to the controller, for
    /// the same reason: there is one document and there are two windows, and a
    /// window that edited its own copy would be a second layout nobody asked
    /// for. The window reports what happened in it; the controller decides.
    var onUndo: (() -> Void)?
    var onSplit: ((_ rid: Int, _ fraction: Double, _ cut: Cut, _ minimum: Double) -> Void)?

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

        // The cut line follows the cursor, so the window has to hear about a
        // cursor that is only moving. Off by default, and the tracking area in
        // the view is not enough on its own.
        acceptsMouseMovedEvents = true

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

    /// The keyboard is handled here and not in the view, because the window is
    /// the responder that is certain to see it. Whatever holds focus — the
    /// content view, the Done button, or nothing at all — an unhandled key
    /// walks up the chain and arrives here; a view that is not first responder
    /// would simply never be asked.
    ///
    /// 53 is Escape, read from the key code and not from the characters,
    /// because the characters depend on the keyboard layout and this key does
    /// not. ⌘Z is read from the characters, because *that* one is a letter and
    /// its key code depends on the layout.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return cancel(nil) }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            return onUndo?() ?? ()
        }
        super.keyDown(with: event)
    }

    /// ⇧ rotates the cut, and it has to rotate it **without the mouse moving** —
    /// you hold the modifier to see what it would do. Nothing else in the app
    /// needs this event, and a cut line that only turned when you jiggled the
    /// cursor would read as a bug in the modifier.
    override func flagsChanged(with event: NSEvent) {
        editorView?.modifiersChanged(to: event.modifierFlags)
        super.flagsChanged(with: event)
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

    /// What a click right now would do.
    ///
    /// It is recomputed from the cursor rather than remembered, so there is no
    /// state to get out of step with the pointer — and it is `Equatable` so that
    /// a redraw only happens when the answer changed. A `mouseMoved` arrives
    /// dozens of times a second and this view is 5120 points wide.
    private struct Hover: Equatable {
        let rid: Int
        let cut: Cut
        /// Where the cut would fall, as a fraction of the screen's usable area
        /// along the axis being cut — the units the document works in.
        let fraction: Double
        /// The line to draw, in view coordinates.
        let line: CGRect
    }

    /// §5 says "the real desktop dimmed to 40%", and this is the reading it
    /// takes: the desktop is left at 40% of itself, so the fill over it is 60%
    /// black. Dark enough that a white outline reads at a glance, light enough
    /// that you can still see which window is where — which matters, because
    /// the point of editing over the real desktop instead of a grey panel is
    /// seeing what your zones would do to the windows you actually have open.
    private static let desktopBrightness: CGFloat = 0.4

    /// The narrowest piece a click is allowed to leave behind, in points.
    ///
    /// Not a judgement about useful window sizes — it is there so that a click
    /// aimed at a boundary does not become a sliver. That makes the number a
    /// question about aim, and the answer is "comfortably more than the eight
    /// points the drag threshold already calls a steady hand". Below this the
    /// cut line is not drawn at all, so the rule explains itself: no line, no
    /// split, and you can see where the band ends.
    private static let smallestPiece: CGFloat = 40

    /// The screen's usable area in CG coordinates. Zones are fractions of this,
    /// and this view covers exactly it — that equality is the 1:1 claim, and
    /// `Coords.cgToView` is where it gets cashed in.
    private let area: CGRect

    private let hud = EditorHUD()
    private var document: EditorDocument?
    private var note: String?

    /// Last known cursor position in view coordinates, and whether ⇧ is down.
    /// Both are kept rather than read from the current event, because the two
    /// arrive separately: ⇧ has to turn the cut line while the mouse is still,
    /// and the mouse has to move the line while ⇧ is still held.
    private var cursor: CGPoint?
    private var shiftHeld = false
    private var hover: Hover?
    private var mouseDownAt: CGPoint?

    private var host: EditorWindow? { window as? EditorWindow }

    init(frame: NSRect, area: CGRect) {
        self.area = area
        super.init(frame: frame)
        addSubview(hud)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Zonas builds its windows in code") }

    func show(_ document: EditorDocument, note: String?) {
        self.document = document
        self.note = note
        // The document just changed under the cursor, so what a click would do
        // has changed with it.
        recomputeHover()
        updateHUD()
        needsDisplay = true
    }

    // MARK: - What is drawn

    /// `viewFrames` draws `frame` and not `rect`, which is the same call the
    /// drag overlay makes and for the same reason: the frame is the rectangle a
    /// window dropped here is given, gap and margin included. An editor showing
    /// a shape no window will ever be given is §3e back again, in the one place
    /// where the drawing is not a preview of the product but the product.
    private func boxes(of document: EditorDocument) -> [Box] {
        let layout = document.layout
        return layout.viewFrames(in: area).enumerated().map {
            Box(rect: $1, name: layout.zones[$0].name)
        }
    }

    /// The document as it would be if you clicked now.
    ///
    /// It is a whole candidate document and not two rectangles worked out by
    /// hand, which is the point: the preview goes through the same `split` and
    /// the same `viewFrames` as the real thing, so it cannot show you a
    /// different answer from the one you are about to get. `EditorDocument` is
    /// a value type precisely so this costs a copy and risks nothing.
    private func candidate(for hover: Hover) -> EditorDocument? {
        guard var document else { return nil }
        guard document.split(rid: hover.rid, at: hover.fraction, hover.cut,
                             minimum: minimumFraction(for: hover.cut)) else { return nil }
        return document
    }

    private func minimumFraction(for cut: Cut) -> Double {
        Self.smallestPiece / (cut == .vertical ? area.width : area.height)
    }

    private func updateHUD() {
        guard let document else { return }
        let zones = document.zones.count == 1 ? "1 zone" : "\(document.zones.count) zones"
        // The usable area, not the display's resolution, because that is what
        // the fractions are fractions of — and the difference between the two
        // numbers is the menu bar and the Dock, which is exactly the thing this
        // window is sitting below in order to show.
        hud.show(title: document.name,
                 // A note displaces the status line rather than adding to it:
                 // when the file is broken or has moved underneath you, that is
                 // the only thing on this bar worth reading.
                 hint: note ?? "\(zones) · \(Int(area.width)) × \(Int(area.height)) usable",
                 keys: document.canUndo
                     ? "Click to split · ⇧ rotates the cut · ⌘Z undo · ⎋ close"
                     : "Click to split · ⇧ rotates the cut · ⎋ close")
        layOutHUD()
    }

    // MARK: - The cursor

    /// `.inVisibleRect` means the area follows the view's size, so this never
    /// has to be redone by hand when a screen changes shape underneath it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            // `.activeAlways` and not `.activeInKeyWindow`: the editor is a
            // floating panel over other people's windows, and the cut line has
            // to follow the cursor on the screen you are looking at whether or
            // not you have clicked on it yet.
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) { cursorMoved(to: event) }
    override func mouseDragged(with event: NSEvent) { cursorMoved(to: event) }
    override func mouseEntered(with event: NSEvent) { cursorMoved(to: event) }

    /// The cursor left this screen — most often for the other one, which has its
    /// own window and its own hover. Leaving the line drawn here would put two
    /// cut lines on the desk at once, only one of which a click would honour.
    override func mouseExited(with event: NSEvent) {
        cursor = nil
        setHover(nil)
    }

    func modifiersChanged(to flags: NSEvent.ModifierFlags) {
        shiftHeld = flags.contains(.shift)
        recomputeHover()
    }

    private func cursorMoved(to event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        shiftHeld = event.modifierFlags.contains(.shift)
        recomputeHover()
    }

    private func recomputeHover() {
        guard let document, let cursor else { return setHover(nil) }

        let hits = document.layout.hitRects(in: area)
        guard let index = Layout.smallestIndex(containing: cursor, in: hits) else {
            return setHover(nil)
        }
        let rect = hits[index]
        let cut = shiftHeld ? Cut.default(for: rect).rotated : Cut.default(for: rect)

        // The cursor's coordinate along the axis being cut, expressed as a
        // fraction of the usable area — which is what the document speaks. X is
        // a straight scale; Y is measured from the top, because that is the end
        // `Zone.y` counts from and this view counts from the other one.
        let fraction = cut == .vertical
            ? Double(cursor.x / area.width)
            : Double(1 - cursor.y / area.height)

        let line = cut == .vertical
            ? CGRect(x: cursor.x, y: rect.minY, width: 0, height: rect.height)
            : CGRect(x: rect.minX, y: cursor.y, width: rect.width, height: 0)

        let candidate = Hover(rid: document.zones[index].rid, cut: cut,
                              fraction: fraction, line: line)
        // A cut that would leave a sliver is simply not offered. No line is the
        // whole of the explanation, and it is a better one than a line that does
        // nothing when clicked.
        setHover(self.candidate(for: candidate) == nil ? nil : candidate)
    }

    private func setHover(_ new: Hover?) {
        guard new != hover else { return }   // a mouseMoved that changes nothing draws nothing
        hover = new
        needsDisplay = true
    }

    // MARK: - The click

    /// A click on an unfocused window normally only focuses it, and AppKit
    /// swallows it. Here that means: leave the editor for another app, come
    /// back, click a zone, and nothing happens — click again and it splits.
    ///
    /// It is the right default almost everywhere and wrong here, because the
    /// cut line is already following the cursor while the window is unfocused
    /// (the tracking area is `.activeAlways`). The user can *see* what the click
    /// will do before making it, so swallowing it is pure loss: no surprise is
    /// being prevented, and "the first click does nothing" is exactly the
    /// did-that-work? confusion this editor exists to avoid.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = convert(event.locationInWindow, from: nil)
        cursorMoved(to: event)
    }

    /// The split happens on mouse **up**, and only if the cursor stayed put.
    ///
    /// A click and the beginning of a drag are the same `mouseDown`, and the
    /// next stretch of this editor is dragging edges. Deciding on the way up,
    /// against the same eight-point threshold the drag monitor already uses,
    /// means that gesture can be added without taking this one apart.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        let up = convert(event.locationInWindow, from: nil)
        guard let down = mouseDownAt, hypot(up.x - down.x, up.y - down.y) < 8 else { return }
        guard let hover else { return }

        host?.onSplit?(hover.rid, hover.fraction, hover.cut, minimumFraction(for: hover.cut))
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

        guard let document else { return }

        // While a cut is being offered, **the whole screen shows the layout you
        // would get**, not the one you have with a line drawn over it. §5's "the
        // screen is the preview" taken at its word: the two pieces are named and
        // measured where they will be, so there is nothing left to imagine and
        // no second representation that could disagree with the first.
        let previewing = hover.flatMap(candidate(for:))
        let hovered = previewing ?? document

        for box in boxes(of: hovered) {
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
            let path = NSBezierPath(roundedRect: box.rect, xRadius: 14, yRadius: 14)
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 2
            path.stroke()

            draw(box)
        }

        if let hover, previewing != nil { draw(hover) }
    }

    /// The cut itself, drawn over the preview it produced.
    ///
    /// It is the accent colour for the same reason the drag overlay's active
    /// zone is: in this app, accent means "this is what is about to happen".
    private func draw(_ hover: Hover) {
        let line = NSBezierPath()
        line.move(to: CGPoint(x: hover.line.minX, y: hover.line.minY))
        line.line(to: CGPoint(x: hover.line.maxX, y: hover.line.maxY))
        line.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        line.stroke()
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

        // A zone can be cut down to 40 points, at which point its own label is
        // taller than it is. Drawing it anyway would put text across the
        // neighbours, so a piece too small to say what it is says nothing —
        // and the bar still names the layout.
        guard box.rect.height > block + 8, box.rect.width > max(nameSize.width, sizeSize.width) + 8
        else { return }

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
    /// §5's "contextual help line that changes with what you are touching", and
    /// it is a line of its own rather than more words on the status line because
    /// the two answer different questions — what you are looking at, and what
    /// you can do to it. The direct antidote to FancyZones' discoverability
    /// problem costs three labels.
    private let keysLabel = NSTextField(labelWithString: "")
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
        keysLabel.font = .systemFont(ofSize: 11)
        keysLabel.textColor = .tertiaryLabelColor

        doneButton.bezelStyle = .rounded

        let text = NSStackView(views: [titleLabel, hintLabel, keysLabel])
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

    func show(title: String, hint: String, keys: String) {
        titleLabel.stringValue = title
        hintLabel.stringValue = hint
        keysLabel.stringValue = keys
        needsLayout = true
    }
}
