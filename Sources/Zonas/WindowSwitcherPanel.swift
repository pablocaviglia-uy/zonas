import AppKit

/// What ⌥Tab draws while ⌥ is held: a strip with one icon per window and
/// where each one is, the chosen window's title under it, and — when Zonas is
/// allowed to take one — a picture of the chosen window above.
///
/// **A strip and not a list.** The first version was a list, one row per
/// window with the title on the left and the application on the right, and
/// it read like a settings table: two columns with nothing between them, the
/// application's name twice on most rows, and the two rows for two Claude
/// windows identical. The strip is the shape ⌘Tab already taught everybody,
/// and what tells two windows of one application apart is the label under
/// each icon — the zone it is in, which only Zonas knows.
///
/// **It never takes the keyboard.** The keys arrive as hot keys and ⌥ coming
/// up is read off the modifier state, so the panel is only ever a picture —
/// which is what leaves the application you were in as the active one until
/// the moment you choose, with the window you were in still first in the
/// order that the next ⌥Tab reads.
///
/// **The picture is optional.** It needs the Screen Recording permission,
/// which Zonas does not ask for unless somebody chooses "Show Window
/// Previews…" in the menu: `WindowPreviews` says why. Without it the panel is
/// the strip and the title, and nothing is missing that the switcher needs.
final class WindowSwitcherPanel {

    struct Row {
        var icon: NSImage?
        /// The window's title, its application's signature taken off.
        var title: String
        /// Whose it is and where: "Microsoft Teams · Derecha 4".
        var detail: String
        /// Under the icon: the zone it is in, or its title when it is in none.
        var label: String
        /// Minimized, or its application hidden: drawn faded, as the Dock
        /// draws them.
        var isAway = false
    }

    /// A window's icon was clicked.
    var onPick: ((Int) -> Void)?

    /// The pointer moved onto a window's icon.
    var onPoint: ((Int) -> Void)?

    /// Where the pointer was when the strip appeared, until it moves.
    ///
    /// A pointer that happens to be resting where the strip appears has not
    /// chosen anything, and taking its icon as the choice would change what
    /// somebody pressing Tab is looking at for no reason they can see. ⌘Tab
    /// waits for the pointer to move as well.
    private var restingAt: NSPoint?

    /// The size a picture has to fit, in points, and the scale of the screen
    /// it is shown on — what a capture should be taken at. Zero when the panel
    /// has no room for a picture.
    private(set) var previewBox: CGSize = .zero
    private(set) var scale: CGFloat = 2

    private var panel: NSPanel?
    private var cells: [SwitcherCellView] = []
    private let preview = PreviewView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    private var rows: [Row] = []
    private var selected = 0
    private var first = 0
    private var strip = WindowSwitcher.Strip(cell: 84, visible: 0)

    private static let padding: CGFloat = 18
    /// An icon and two lines of label: "Izquierda Arriba" is two words, and
    /// on one line it was "Izquierda…".
    private static let cellHeight: CGFloat = 106
    private static let captionHeight: CGFloat = 40
    /// Sixteen by ten: most windows are wider than they are tall, and the
    /// ultrawide's are much wider, which this letterboxes rather than crops.
    private static let previewRatio: CGFloat = 0.625

    /// How wide the picture is: seven tenths of the strip, within limits.
    ///
    /// A fixed 560 looked lost above a strip of fourteen windows — nearly a
    /// thousand points of it, with empty panel either side of the picture —
    /// and a picture as wide as the strip would be taller than a laptop's
    /// screen can spare.
    private static func previewWidth(under strip: CGFloat, room: CGFloat) -> CGFloat {
        min(room, min(720, max(480, strip * 0.7))).rounded()
    }

    /// Sizes, places and fills in the panel without putting it on screen, so
    /// that `reveal` has nothing left to do but that.
    ///
    /// The two are apart because of when each happens: the panel is prepared
    /// while ⌥Tab waits to see whether the press was a tap, and revealed only
    /// once it was not — so the work of drawing it is hidden inside a wait
    /// that has to happen anyway, instead of being added on after it.
    func prepare(_ rows: [Row], selected: Int, on screen: NSScreen?, showsPreview: Bool) {
        guard let screen = screen ?? NSScreen.main else { return }
        self.rows = rows
        self.selected = selected
        scale = screen.backingScaleFactor

        // Nine tenths of the screen at most; past that the cells shrink, and
        // past the smallest cell the strip scrolls.
        let area = screen.visibleFrame
        let room = area.width * 0.9 - Self.padding * 2
        strip = WindowSwitcher.strip(count: rows.count, room: room)
        let stripWidth = strip.cell * CGFloat(strip.visible)

        let previewWidth = showsPreview ? Self.previewWidth(under: stripWidth, room: room) : 0
        previewBox = CGSize(width: previewWidth, height: (previewWidth * Self.previewRatio).rounded())

        // Never narrower than a title needs, even for two windows.
        let content = max(stripWidth, previewBox.width, 360)
        let width = content + Self.padding * 2
        let captionY = Self.padding - 2
        let stripY = captionY + Self.captionHeight + 4
        let previewY = stripY + Self.cellHeight + 14
        let height = (showsPreview ? previewY + previewBox.height : stripY + Self.cellHeight) + Self.padding

        let panel = self.panel ?? makePanel()
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                           width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        preview.isHidden = !showsPreview
        preview.frame = NSRect(x: (width - previewBox.width) / 2, y: previewY,
                               width: previewBox.width, height: previewBox.height)
        title.frame = NSRect(x: Self.padding, y: captionY + 18, width: content, height: 20)
        detail.frame = NSRect(x: Self.padding, y: captionY, width: content, height: 16)
        makeCells(strip.visible, originX: (width - stripWidth) / 2, y: stripY)

        first = WindowSwitcher.top(showing: selected, from: 0, count: rows.count, capacity: strip.visible)
        fill()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func reveal() {
        guard let panel, !rows.isEmpty else { return }
        restingAt = NSEvent.mouseLocation
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    private func pointed(at index: Int) {
        if let resting = restingAt {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - resting.x, now.y - resting.y) > 2 else { return }
            restingAt = nil
        }
        guard index != selected else { return }
        onPoint?(index)
    }

    /// Moves the choice, on screen or not: a Tab pressed during the wait has
    /// to be in the panel by the time it appears.
    func select(_ index: Int) {
        guard index != selected else { return }
        let previous = selected
        selected = index
        guard panel != nil, !rows.isEmpty else { return }
        let top = WindowSwitcher.top(showing: index, from: first, count: rows.count, capacity: strip.visible)
        if top != first {
            first = top
            fillCells()
        } else {
            // A normal Tab only changes two selection backgrounds. Rebinding
            // every icon and wrapping every label here made selection pay for
            // the whole strip even when it had not scrolled.
            for (position, chosen) in [(previous, false), (index, true)] {
                let offset = position - first
                if cells.indices.contains(offset) { cells[offset].isChosen = chosen }
            }
        }
        fillCaption()
    }

    /// A picture for one window, shown if that window is the one chosen.
    /// `nil` puts back the stand-in: the application's icon.
    func showPreview(_ image: NSImage?, forRow index: Int) {
        guard index == selected else { return }
        if preview.image !== image { preview.image = image }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Building it

    private func makePanel() -> NSPanel {
        // Not deferred: the window's backing is made here, when `warmUp`
        // prepares the panel out of sight at launch, rather than on the first
        // reveal, in front of somebody waiting for it.
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        // An NSPanel hides whenever its application is not the active one,
        // and Zonas never is: left at its default, this panel would be ordered
        // in and never seen.
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        // The mask is what shapes the material itself, which is blended behind
        // the window by the WindowServer rather than drawn in the view the way
        // everything else is.
        background.maskImage = Self.roundedMask(radius: 18)
        panel.contentView = background

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byTruncatingMiddle
        [preview, title, detail].forEach(background.addSubview)

        self.panel = panel
        return panel
    }

    /// As many cells as are shown, left to right.
    private func makeCells(_ count: Int, originX: CGFloat, y: CGFloat) {
        guard let content = panel?.contentView else { return }
        while cells.count < count {
            let cell = SwitcherCellView()
            content.addSubview(cell)
            cells.append(cell)
        }
        while cells.count > count {
            cells.removeLast().removeFromSuperview()
        }
        for (offset, cell) in cells.enumerated() {
            let frame = NSRect(x: originX + CGFloat(offset) * strip.cell, y: y,
                               width: strip.cell, height: Self.cellHeight)
            if cell.frame != frame {
                cell.frame = frame
                cell.needsLayout = true
            }
        }
    }

    private func fill() {
        fillCells()
        fillCaption()
    }

    private func fillCells() {
        for (offset, cell) in cells.enumerated() {
            let index = first + offset
            guard rows.indices.contains(index) else {
                if !cell.isHidden { cell.isHidden = true }
                continue
            }
            if cell.isHidden { cell.isHidden = false }
            if cell.icon.image !== rows[index].icon { cell.icon.image = rows[index].icon }
            let opacity: CGFloat = rows[index].isAway ? 0.45 : 1
            if cell.icon.alphaValue != opacity { cell.icon.alphaValue = opacity }
            if cell.label.stringValue != rows[index].label { cell.label.stringValue = rows[index].label }
            cell.isChosen = index == selected
            if cell.representedIndex != index {
                cell.representedIndex = index
                cell.onClick = { [weak self] in self?.onPick?(index) }
                cell.onPoint = { [weak self] in self?.pointed(at: index) }
            }
        }
    }

    private func fillCaption() {
        guard rows.indices.contains(selected) else { return }
        if title.stringValue != rows[selected].title { title.stringValue = rows[selected].title }
        if detail.stringValue != rows[selected].detail { detail.stringValue = rows[selected].detail }
        if preview.placeholder !== rows[selected].icon { preview.placeholder = rows[selected].icon }
        if preview.image != nil { preview.image = nil }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One window in the strip: its application's icon, and where it is.
private final class SwitcherCellView: NSView {

    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onPoint: (() -> Void)?
    var representedIndex: Int?

    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            label.textColor = isChosen ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        [icon, label].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    override func layout() {
        super.layout()
        // The icon is as big as the cell allows, up to 56 points: ⌘Tab's
        // are bigger, but these carry a label as well.
        let side = min(56, bounds.width - 24)
        icon.frame = NSRect(x: (bounds.width - side) / 2, y: bounds.height - 10 - side,
                            width: side, height: side)
        // Two lines' worth, hung from just under the icon, so a one-line
        // label sits where a two-line one starts.
        label.frame = NSRect(x: 3, y: icon.frame.minY - 5 - 28, width: bounds.width - 6, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isChosen else { return }
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }

    // The panel is never key, so without this the first click on a cell would
    // be spent making it so — and it never would be.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // `.activeAlways`, because the panel is never key and Zonas is never the
    // active application: any other option and the pointer would never be
    // heard at all.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onPoint?() }
    override func mouseMoved(with event: NSEvent) { onPoint?() }
}

/// A ring around the chosen window, where it actually is on the desktop, with
/// the picture of that window inside it when there is one.
///
/// The strip says which window; this says where. A window behind three others,
/// or on the other screen, is found by looking rather than by reading its
/// zone's name — and **the ring itself needs no permission**, which is why it
/// was built before the picture and why it is still the whole of this on a
/// machine that never granted Screen Recording.
///
/// The picture is the association it could not make on its own: the ring around
/// a covered window frames three other applications' pixels, so it says where
/// to look without saying what is there, and the answer had to be read off the
/// strip and carried across the screen. Dropped into the ring, the two are one
/// glance. `RingView` is where the drawing of it is argued.
final class WindowHighlight {

    /// One window per **display**, not one the size of the thing being ringed.
    ///
    /// It used to be the second: a borderless window at the chosen window's
    /// frame grown by five points, which is all a ring needs. Three of the four
    /// things drawn now are about the *rest* of the screen — the scrim, and the
    /// two pairs of guides that run off to the bezels — so the view has to be
    /// the screen. Keyed by `displayID` for the reason `OverlayController`
    /// documents: AppKit hands out fresh `NSScreen` instances on every display
    /// reconfiguration, so a dictionary keyed by one grows an entry and a window
    /// every time a monitor is plugged in and never lets go of the old ones.
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var dismissal: Timer?

    /// Rings a window, given its frame in CG coordinates, and puts `picture`
    /// inside the ring — `nil` for no permission, or for the moment before the
    /// first capture of this window has arrived.
    func show(_ frame: CGRect, picture: NSImage? = nil) {
        dismissal?.invalidate(); dismissal = nil
        let cocoa = Coords.cgToCocoa(frame)
        let spotlight = Spotlight.isOn()

        for screen in NSScreen.screens {
            guard let display = screen.displayID else { continue }
            // The window's frame in this screen's own view coordinates: the
            // view fills the screen, so it is the global rectangle less the
            // screen's origin. A second monitor does not start at zero, and
            // measuring against the desktop instead would put the hole off the
            // end of every screen but the first.
            let hole = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let bounds = CGRect(origin: .zero, size: screen.frame.size)

            // With the spotlight off there is nothing to say about a screen the
            // window is not on, and a full-screen transparent window per monitor
            // for the sake of drawing nothing in it is compositing work for no
            // picture.
            guard spotlight || Spotlight.holds(hole, in: bounds) else {
                windows[display]?.orderOut(nil)
                continue
            }

            let window = windows[display] ?? make(on: display)
            if window.alphaValue != 1 { window.alphaValue = 1 }
            if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
            (window.contentView as? RingView)?.show(hole: hole,
                                                    picture: picture,
                                                    spotlight: spotlight)
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    func hide() {
        dismissal?.invalidate(); dismissal = nil
        for window in windows.values {
            window.orderOut(nil)
            window.alphaValue = 1
            // Or the next window ringed with no picture of its own — a different
            // application, as often as not — appears inside the last one's for as
            // long as it takes the first capture to arrive.
            (window.contentView as? RingView)?.forget()
        }
    }

    /// Keep the stream moving during dismissal without restarting its styling.
    func updatePicture(_ picture: NSImage) {
        for window in windows.values where window.isVisible {
            (window.contentView as? RingView)?.updatePicture(picture)
        }
    }

    func dismiss(canReveal: @escaping () -> Bool, completion: @escaping () -> Void) {
        dismissal?.invalidate()
        let began = DispatchTime.now()
        var transition = PreviewDismissal()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.dismissal === timer else { timer.invalidate(); return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000_000
            let ready = elapsed >= PreviewDismissal.effectsDuration + PreviewDismissal.neutralDuration
                && canReveal()
            let appearance = transition.advance(elapsed: elapsed, windowIsReady: ready)
            for window in self.windows.values where window.isVisible {
                (window.contentView as? RingView)?.setEffectsOpacity(CGFloat(appearance.effects))
                window.alphaValue = CGFloat(appearance.picture)
            }
            if appearance.isComplete {
                self.hide()
                completion()
            }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func make(on display: CGDirectDisplayID) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Click-through: it lies over the window being chosen and, as often
        // as not, under the strip the pointer is choosing with. It now lies
        // over every *other* window too, which makes this line load-bearing
        // rather than tidy.
        window.ignoresMouseEvents = true
        // Above everything but the strip, the chosen window included, since
        // that one can be anywhere in the stack.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = RingView()
        windows[display] = window
        return window
    }
}

/// The scrim, the guides, the ring, and the picture of the window inside it.
final class RingView: NSView {

    /// How much of the picture is let through, over the black it is drawn on.
    ///
    /// Dimmer than the window itself, and washed with the accent colour, so
    /// that the ghost is never read as the window having already come forward.
    /// On commit, the styling fades first and the picture returns to its source
    /// colours before the real window is revealed underneath it.
    private static let fade: CGFloat = 0.78

    /// The window this ring is around, in this view's coordinates.
    private var hole: CGRect = .zero

    /// The picture of that window.
    private var picture: NSImage?

    /// Whether the rest of the screen is pushed back. Off, this view draws what
    /// it drew before the spotlight existed: a ring, and nothing else.
    private var spotlight = true
    private var effectsOpacity: CGFloat = 1

    func show(hole: CGRect, picture: NSImage?, spotlight: Bool) {
        guard hole != self.hole || picture !== self.picture || spotlight != self.spotlight
                || effectsOpacity != 1 else {
            return
        }
        self.hole = hole
        self.picture = picture
        self.spotlight = spotlight
        effectsOpacity = 1
        needsDisplay = true
    }

    func updatePicture(_ picture: NSImage) {
        guard Spotlight.holds(hole, in: bounds), picture !== self.picture else { return }
        self.picture = picture
        needsDisplay = true
    }

    func setEffectsOpacity(_ opacity: CGFloat) {
        effectsOpacity = min(1, max(0, opacity))
        needsDisplay = true
    }

    func forget() {
        picture = nil
        hole = .zero
        effectsOpacity = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let onThisScreen = Spotlight.holds(hole, in: bounds) && !hole.isEmpty

        // The hole is the window itself; the ring sits just outside it, inner
        // edge on the window's own edge, which is where it has always been.
        let ring = NSBezierPath(roundedRect: hole.insetBy(dx: -2.5, dy: -2.5),
                                xRadius: 14, yRadius: 14)

        if spotlight && effectsOpacity > 0 {
            drawScrim(cutting: onThisScreen ? hole : nil)
            if onThisScreen { drawGuides() }
        }

        guard onThisScreen else { return }

        if let picture { drawGhost(picture, in: ring) }
        // Over the picture, and lighter when there is one: the wash is what
        // keeps a ringed window the accent colour rather than just a dimmed
        // one, and at 0.12 over a picture it tinted the whole thing blue.
        if effectsOpacity > 0 {
            NSColor.controlAccentColor.withAlphaComponent((picture == nil ? 0.12 : 0.08) * effectsOpacity).setFill()
            ring.fill()
            drawRing(ring)
        }
    }

    /// Everything that is not the chosen window, pushed back.
    ///
    /// **A hole and not a lighter fill, and §5 is why.** The obvious version
    /// paints the screen dark and the chosen window lighter, and over a scrim a
    /// lighter fill is *additive* where the scrim is multiplicative: on a dark
    /// desktop that comes out brighter than not dimming at all, which is the
    /// mistake the editor's first build shipped and the reason it does not fill
    /// its zones. Here the window is left alone and the black is drawn
    /// everywhere else, with `evenOdd` cutting it out — so the chosen window is
    /// not made brighter, it is the only thing that was never made darker.
    private func drawScrim(cutting hole: CGRect?) {
        let scrim = NSBezierPath(rect: bounds)
        if let hole {
            scrim.append(NSBezierPath(roundedRect: hole, xRadius: 12, yRadius: 12))
            scrim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Spotlight.dim * effectsOpacity).setFill()
        scrim.fill()
    }

    /// Two lines through the window's vertical edges and two through its
    /// horizontal ones, clipped out of the window itself.
    ///
    /// Clipped rather than simply drawn, because a line across the chosen
    /// window is a line across the one thing on the screen that is meant to be
    /// untouched — and with the picture in the ring it would be a line across a
    /// picture of it, which reads as a crack in the glass.
    private func drawGuides() {
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(roundedRect: hole, xRadius: 12, yRadius: 12))
        outside.windingRule = .evenOdd
        outside.addClip()

        NSColor.controlAccentColor.withAlphaComponent(Spotlight.guideAlpha * effectsOpacity).setFill()
        for line in Spotlight.guides(around: hole, in: bounds) {
            line.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The ring, with a glow around it.
    ///
    /// The glow is an `NSShadow` in the accent colour with no offset, which is
    /// the cheapest halo there is and needs no second window: the ring used to
    /// live in one exactly five points bigger than the window, so there was
    /// nowhere for a glow to go. Now the view is the screen and it has room.
    ///
    /// Stroked twice. Once is a haze that reads as the ring being slightly out
    /// of focus rather than as light coming off it; the second pass lands the
    /// shadow on top of itself and is what turns it into a glow.
    private func drawRing(_ ring: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.85 * effectsOpacity)
        glow.shadowBlurRadius = 22
        glow.shadowOffset = .zero
        glow.set()

        NSColor.controlAccentColor.withAlphaComponent(effectsOpacity).setStroke()
        ring.lineWidth = 5
        ring.stroke()
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The picture, faded, exactly over where the window is.
    ///
    /// The ring sits outside the window, so the picture goes on `hole` — the
    /// window's own rectangle — at the size the window itself has. That it
    /// lands there rather than filling the ring is the whole of the
    /// association: what you see is the shape you are about to get, in the
    /// place you are about to get it.
    ///
    /// `fit` and not the rectangle itself, because the picture can be a press
    /// or two old and a window resized since would otherwise be stretched.
    private func drawGhost(_ picture: NSImage, in ring: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        // Do not leave the ring's enlarged black footprint around the neutral
        // image after its blue border is gone.
        let imageShape = NSBezierPath(roundedRect: hole, xRadius: 12, yRadius: 12)
        imageShape.addClip()
        // **Opaque, and that is the measurement in this view.** The obvious
        // version is the picture at some alpha straight over what is already
        // there, and the case this ring exists for is the case where that is
        // worst: the pixels underneath belong to the windows *covering* the one
        // being pointed at, so a translucent ghost reads as two windows at once.
        // Drawn on a ground of 0.92 instead of this one, over two Claude
        // windows, the one behind came through at up to 175 of 255 levels — its
        // white text, the only part of it anybody reads. The mean difference
        // over the whole ring was 2 levels, which is why a mean is not what
        // settled it.
        NSColor.black.setFill()
        imageShape.fill()
        let size = WindowSwitcher.fit(picture.size, into: hole.size, enlarging: true)
        picture.draw(in: NSRect(x: hole.midX - size.width / 2, y: hole.midY - size.height / 2,
                               width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver,
                     fraction: 1 - (1 - RingView.fade) * effectsOpacity)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The picture of the chosen window, or its application's icon until there is
/// one.
private final class PreviewView: NSView {

    var image: NSImage? { didSet { needsDisplay = true } }
    var placeholder: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else {
            NSColor.white.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            if let placeholder {
                let side = min(96, bounds.height * 0.4)
                placeholder.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                            width: side, height: side))
            }
            return
        }
        let size = WindowSwitcher.fit(image.size, into: bounds.size)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}
