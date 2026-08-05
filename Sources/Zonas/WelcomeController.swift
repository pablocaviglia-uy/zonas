import AppKit

/// The window a stranger meets the first time they open Zonas.
///
/// It answers the three questions that otherwise get the app uninstalled within
/// a minute, in the order they occur to somebody who has just double-clicked an
/// icon and watched nothing happen: what is this, **where did it go**, and why
/// does it not work.
///
/// **One screen and not a paged flow.** The competitor ships six pages, each
/// with a looping video, and manages across all six never to mention either the
/// Accessibility permission or the menu bar — which is to say it spends four
/// megabytes and six clicks without answering any of the three questions. Every
/// other app in this genre that ships anything at all ships one screen.
///
/// **It is not a gate.** Rectangle's permission window calls `exit(1)` when you
/// close it and MacsyZones' calls `exit(0)`; quitting a menu bar utility because
/// somebody closed a window is hostile, and reading the manual is a perfectly
/// good reason to be here with the permission still off. Closing it is allowed
/// and the window says how to get it back.
final class WelcomeController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let content = WelcomeView()

    /// Where the app is told to look for "have I done this already".
    ///
    /// Injectable only so the test suite does not write into the real domain;
    /// nothing in the app ever passes anything else.
    private let defaults: UserDefaults

    /// Asked for the live state of the permission, because this window must not
    /// grow a poller of its own. `AppDelegate.waitForPermission()` already runs
    /// one, it already knows the answer, and a second timer asking the same
    /// question 1.5 s out of phase is how two parts of one app come to disagree
    /// on screen.
    var onGrantPermission: (() -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    var isOpen: Bool { window != nil }

    // MARK: - Opening

    /// Opens it if the user has never closed it. Called once, at launch.
    func openIfFirstLaunch(readiness: Welcome.Readiness) {
        guard Welcome.shouldOpen(defaults) else { return }
        Log.write("welcome: first launch, opening the window")
        open(readiness: readiness)
    }

    /// Opens it because somebody asked — the menu item, or re-opening the app
    /// from the Finder.
    func open(readiness: Welcome.Readiness) {
        if let window {
            activate(window)
            update(readiness)
            return
        }

        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeView.width, height: 200),
            // `.titled` for the close button, which is the control every person
            // on a Mac already knows. Deliberately not `.resizable`: everything
            // in here is measured text and two drawings sized to the screen's
            // own proportions, and there is no second size at which any of it is
            // better.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        // Owned by this property, so ARC is what should free it. Left at the
        // default, the close button alone would over-release — the same reason
        // `EditorWindow` sets it, arrived at from the other direction.
        window.isReleasedWhenClosed = false

        // **An ordinary window, and this was `.floating` for one build.** The
        // argument for floating was that the permission row has to stay visible
        // while the user is away granting the permission, and it is a good
        // argument for the wrong mechanism: tried on the machine, a 560-point
        // window pinned above everything lands squarely on top of the System
        // Settings pane it just sent you to, and you cannot see the switch you
        // came to flip. Staying visible is a question about *where* the window
        // is, not about which pile it is in — see `stepAside`.
        window.level = .normal

        window.delegate = self
        window.contentView = content
        content.controller = self
        self.window = window

        content.fill(layout: LayoutStore.shared.layout,
                     screen: screenUnderCursor() ?? NSScreen.main,
                     canLaunchAtLogin: LaunchAtLogin.isInstalledCopy,
                     launchesAtLogin: LaunchAtLogin.isEnabled)
        update(readiness)

        window.setContentSize(content.fittingSize)
        place(window)
        activate(window)
    }

    /// What the live state is now.
    ///
    /// Called by `AppDelegate` every time it learns something, which is at
    /// startup and on the watchdog tick that succeeds. It is safe to call when
    /// the window is closed and does nothing then.
    func update(_ readiness: Welcome.Readiness) {
        guard window != nil else { return }
        content.show(readiness)
    }

    /// The layout file changed underneath the window.
    ///
    /// Two of the things on this window are read out of that file — the key the
    /// gesture is described with, and the picture of the zones — so an open
    /// window that did not follow it would be showing somebody a diagram of a
    /// layout they had just replaced. That is §3e's lying preview arriving
    /// through a third door, and the editor already refreshes for the same
    /// reason on the same notification.
    func refresh() {
        guard window != nil else { return }
        content.fill(layout: LayoutStore.shared.layout,
                     screen: window?.screen ?? NSScreen.main,
                     canLaunchAtLogin: LaunchAtLogin.isInstalledCopy,
                     launchesAtLogin: LaunchAtLogin.isEnabled)
    }

    /// The menu bar sketch, asked late on purpose.
    ///
    /// `occlusionState` reports an icon that is plainly on screen as hidden for
    /// the first ~80 ms of its life, and takes about three quarters of a second
    /// to settle after the bar changes. Both numbers are measured. Asking at the
    /// moment the window is built would therefore tell a fresh install that its
    /// icon is missing, every time, which is the one thing this section must not
    /// get wrong.
    func showIcon(_ item: NSStatusItem?, on screen: NSScreen?) {
        guard let screen else { return }
        content.show(Welcome.Sketch.of(bar: screen.frame,
                                       notch: screen.notchFrame,
                                       icon: item?.button?.window?.frame,
                                       iconIsVisible: !(item?.isHiddenFromUser ?? true)))
    }

    // MARK: - Closing

    /// The red button, Escape and ⌘W — the three routes that go through
    /// `performClose`, which is to say **the three a person can take**.
    ///
    /// The flag is spent here rather than in `windowWillClose`, and the
    /// difference is not academic: it was written in `windowWillClose` first,
    /// and installing a new build over the running one — which is `pkill -x
    /// Zonas`, a SIGTERM, and AppKit closing its windows on the way out — set
    /// it with nobody having touched the window. That is exactly the case the
    /// flag exists to survive. Anything that ends the process before the user
    /// has finished must leave first launch still owed, because this window is
    /// the only face the app has, and a second launch without it is the grey
    /// icon and the silence the whole thing exists to prevent.
    ///
    /// `windowShouldClose` is not called for a programmatic `close()`, which is
    /// what termination does and what `done` does — so `done` says it too, in
    /// its own words.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return true
    }

    @objc func done(_ sender: Any?) {
        finish()
        window?.close()
    }

    private func finish() {
        guard Welcome.shouldOpen(defaults) else { return }
        Welcome.dismiss(defaults)
        Log.write("welcome: closed — it will not open on its own again")
    }

    /// **The reference is dropped one run loop turn late, and that is the whole
    /// reason this is written out rather than being `window = nil`.** Every one
    /// of the ways out is delivering an event *to this window or to a button
    /// inside it* at the moment it calls close. This property is the last strong
    /// reference, so clearing it here deallocates an `NSWindow` in the middle of
    /// its own event — a crash that depends on the autorelease pool, which means
    /// it does not happen on this machine and does happen on somebody else's.
    /// §5 records the same finding from the editor's two ways out; the
    /// difference is that a titled window has four.
    func windowWillClose(_ notification: Notification) {
        // Cleared now, so anything asking whether the window is up gets the
        // right answer inside this very turn — and kept alive by the block, so
        // the object outlives the event that is closing it.
        let closing = window
        window = nil
        DispatchQueue.main.async { _ = closing }
    }

    @objc func grant(_ sender: Any?) {
        stepAside()
        onGrantPermission?()
    }

    /// Moves the window to the left-hand edge before System Settings opens.
    ///
    /// This is the whole of "stay visible while the user is away", and it
    /// replaces pinning the window above everything else — which did keep it
    /// visible, by covering the pane the user had just been sent to. System
    /// Settings opens centred, so a window against the left edge does not
    /// overlap it and both are readable at once; and because this one is an
    /// ordinary window, dragging Settings over it still works the way dragging a
    /// window over another window works.
    ///
    /// It moves only when it has to, so somebody who has placed the window where
    /// they want it and is re-reading the manual is left alone.
    private func stepAside() {
        guard let window, let visible = window.screen?.visibleFrame else { return }
        let margin: CGFloat = 20
        guard window.frame.minX > visible.minX + margin * 2 else { return }
        window.setFrameOrigin(NSPoint(x: visible.minX + margin, y: window.frame.minY))
    }

    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        onToggleLaunchAtLogin?(sender.state == .on)
        // Asked back rather than assumed: `register()` fails with no way to undo
        // it if the user turned the login item off by hand in Settings, and a
        // checkbox that ticks itself anyway would be the app claiming something
        // the system will contradict at the next login.
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: - Placing it

    /// Centred on the screen the cursor is on, and a little above centre.
    ///
    /// `NSWindow.center()` puts it on the main screen whatever the user is
    /// looking at, which on this desk is the wrong monitor most of the time.
    /// `EditorController.activate()` already picks a screen this way.
    private func place(_ window: NSWindow) {
        let screen = screenUnderCursor() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return window.center() }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            // Golden-ish rather than centred: the sketch of the menu bar is at
            // the top of the window and the menu bar it describes is at the top
            // of the screen, and sitting the window low would put a picture of
            // the bar further from the bar than it needs to be.
            y: visible.midY - size.height / 2 + visible.height * 0.08))
    }

    private func screenUnderCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
    }

    /// `NSApp.activate()` **before** ordering front, which is not optional for
    /// an `.accessory` app: with no Dock icon and no application menu, nothing
    /// else in the system is ever going to decide this window should have focus.
    /// Switching to `.regular` to get it for free is the trade that looks
    /// tempting and is not — it puts a Dock icon on a menu bar utility for as
    /// long as the process lives, not for as long as the window is up.
    private func activate(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The window

/// The welcome window, which exists as a subclass for one reason: **an
/// `.accessory` app has no application menu**, so there is no File ▸ Close to
/// route ⌘W and no Edit menu to route anything else. On any ordinary app those
/// arrive through the menu bar; here nothing handles them and the keystroke does
/// nothing at all, which reads as the window being broken.
///
/// Escape is the same question one layer down. `NSWindow.cancelOperation(_:)`
/// looks for a button carrying Escape as its key equivalent, and this window's
/// two buttons need Return for the action that matters. `EditorWindow` reads
/// key code 53 for exactly this reason and this does the same.
final class WelcomeWindow: NSWindow {

    /// A borderless window has to be told; a titled one already answers `true`.
    /// Stated anyway because the window is created by an app that never becomes
    /// active on its own, and this is the property somebody will come looking
    /// for when Escape does nothing.
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape, read from the key code rather than from the characters
        // because the characters depend on the keyboard layout and this key does
        // not. ⌘W is read from the characters, because that one is a letter and
        // its key code is the thing that moves.
        if event.keyCode == 53 { return performClose(nil) }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return performClose(nil)
        }
        super.keyDown(with: event)
    }
}

// MARK: - The window's contents

/// Everything inside the welcome window.
final class WelcomeView: NSView {

    /// Wide enough for a paragraph to break where it reads well, narrow enough
    /// that the whole window fits on the 13" laptop that is also the machine
    /// most likely to hide the icon behind its notch. The competitor's is 920
    /// points tall against roughly 930 points of usable height there.
    static let width: CGFloat = 560
    private static let margin: CGFloat = 32

    weak var controller: WelcomeController?

    private let headline = NSTextField(labelWithString: "Zonas")
    private let version = NSTextField(labelWithString: "")
    private let gesture = WelcomeView.paragraph()
    private let spanning = WelcomeView.paragraph()
    private let zones = ZonesSketchView()

    private let livesHeading = NSTextField(labelWithString: "It lives in the menu bar")
    private let bar = MenuBarSketchView()
    private let lives = WelcomeView.paragraph()
    private let findIt = WelcomeView.paragraph()

    private let permission = PermissionRow()
    private let loginItem = NSButton(checkboxWithTitle: "Open Zonas at login", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Zonas builds its windows in code") }

    private func build() {
        headline.font = .systemFont(ofSize: 26, weight: .semibold)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        livesHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        findIt.textColor = .secondaryLabelColor

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let titles = NSStackView(views: [headline, version])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(done)
        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        permission.onAction = { [weak self] in self?.controller?.grant(nil) }

        // A spacer that gives way, so Done sits against the right-hand edge and
        // the checkbox against the left.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        let footer = NSStackView(views: [loginItem, spacer, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill

        let column = NSStackView(views: [
            header,
            gesture,
            zones,
            spanning,
            separator(),
            livesHeading,
            bar,
            lives,
            findIt,
            separator(),
            permission,
            footer,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.setCustomSpacing(22, after: header)
        column.setCustomSpacing(20, after: spanning)
        column.setCustomSpacing(8, after: livesHeading)
        column.setCustomSpacing(20, after: findIt)
        column.setCustomSpacing(20, after: permission)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            // Room for the traffic lights, which are drawn over the content now
            // that the title bar is transparent.
            column.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.margin),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])

        for view in [gesture, spanning, lives, findIt] {
            view.widthAnchor.constraint(
                equalToConstant: Self.width - Self.margin * 2).isActive = true
        }
        for view in [zones, bar, permission, footer] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    /// Everything that comes from the layout file and from the machine.
    func fill(layout: Layout, screen: NSScreen?, canLaunchAtLogin: Bool, launchesAtLogin: Bool) {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        version.stringValue = short.map { "Version \($0)" } ?? ""

        gesture.stringValue = Welcome.gesture(layout)
        spanning.stringValue = [Welcome.spanning(layout), Welcome.escape]
            .compactMap { $0 }
            .joined(separator: " ")

        zones.show(layout, on: screen)

        lives.stringValue =
            "There is no Dock icon and no window. From now on Zonas is the small split "
            + "rectangle at the top of the screen — clicking it opens the menu, and that "
            + "is the whole application."

        loginItem.state = launchesAtLogin ? .on : .off
        loginItem.isEnabled = canLaunchAtLogin
        // The same guard `validateMenuItem` applies to the menu item, said out
        // loud rather than left as a control that does nothing. Rule 5: nothing
        // outside /Applications may talk to Background Task Management, not even
        // to read `status`, because the read itself rewrites the recorded path.
        loginItem.toolTip = canLaunchAtLogin
            ? nil
            : "Only the copy in /Applications can register a login item."
    }

    func show(_ readiness: Welcome.Readiness) {
        permission.show(readiness)
        // Return goes to whatever is left to do, which is the permission until
        // there is nothing wrong with it and Done after that. Two buttons cannot
        // both carry it — AppKit draws whichever it finds first as the default
        // one and the other stops responding, which looks exactly like a broken
        // button.
        doneButton.keyEquivalent = readiness.isWorking ? "\r" : ""
    }

    func show(_ sketch: Welcome.Sketch) {
        bar.sketch = sketch
        findIt.stringValue = Self.findingIt(sketch)
    }

    /// What to say about finding the icon, which depends on whether it is
    /// actually there.
    ///
    /// The generic version of this sentence is in the README and has been since
    /// the first release. A README is a page for people who already went
    /// looking; this is the moment it is needed, and by then macOS has already
    /// told us the answer.
    static func findingIt(_ sketch: Welcome.Sketch) -> String {
        let escape = "If you ever cannot find it, open Zonas again from Applications and "
                   + "this window comes back."
        guard !sketch.iconIsVisible else {
            return "Zonas is the highlighted one above. " + escape
        }
        // Measured: macOS does not wrap status items round to the left of the
        // notch. The first one that would cross into it is dropped and so is
        // every one after it — and the newest item is last in that queue, which
        // is exactly an app you installed a minute ago.
        return "macOS is not drawing it: the menu bar is full, and a newly installed "
             + "icon is the first one to be dropped"
             + (sketch.hasNotch ? " into the space behind the notch. " : ". ")
             + "Quit something else that lives up there and it will appear. " + escape
    }

    @objc private func done(_ sender: Any?) { controller?.done(sender) }
    @objc private func toggleLoginItem(_ sender: NSButton) {
        controller?.toggleLaunchAtLogin(sender)
    }

    private static func paragraph() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.isSelectable = false
        return field
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.width - Self.margin * 2).isActive = true
        return line
    }
}

// MARK: - The two drawings

/// The zones the user actually has, at the proportions of the screen they are
/// on.
///
/// Drawn from `Layout.viewFrames(in:)` — the same function the drag overlay and
/// the editor draw from — rather than from a stock picture, for the reason the
/// app icon and the disk image background are drawn in code: a picture of three
/// columns would be wrong for everybody who has edited the file, and wrong the
/// silent way, on the one screen whose job is to be believed.
///
/// §5 warns that a scaled picture of the zones lies, and it is right about an
/// *editor*: one point of an editor has to be one point of the space the zones
/// live in or the numbers are unusable. Nothing here can be dragged, so there
/// are no numbers to be wrong — this is the shape of the layout and the aspect
/// ratio is honest because it comes from the screen.
final class ZonesSketchView: NSView {

    private static let height: CGFloat = 116

    private var frames: [CGRect] = []
    private var box: CGRect = .zero

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func show(_ layout: Layout, on screen: NSScreen?) {
        let area = screen?.cgVisibleFrame ?? CGRect(x: 0, y: 0, width: 1728, height: 1084)
        frames = layout.viewFrames(in: area)
        box = area
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard box.width > 0, box.height > 0 else { return }

        // Fitted rather than stretched, so an ultrawide layout comes out wide
        // and a laptop's comes out nearly square. A sketch that filled the same
        // rectangle whatever the screen would be drawing the one thing this app
        // spends a whole section of its README insisting on — that the layout is
        // a fraction of the screen, not a picture of one.
        let scale = min(bounds.width / box.width, Self.height / box.height)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)

        let screen = NSBezierPath(roundedRect: NSRect(origin: origin, size: size),
                                  xRadius: 6, yRadius: 6)
        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()

        for frame in frames {
            let rect = NSRect(x: origin.x + frame.minX * scale,
                              y: origin.y + frame.minY * scale,
                              width: frame.width * scale,
                              height: frame.height * scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }
}

/// This machine's menu bar, with the notch where the notch is and Zonas where
/// macOS put it.
///
/// A schematic of *your* bar rather than a drawing of a bar: the notch is only
/// drawn on machines that have one, and the icon is only drawn when macOS says
/// it is drawing it too. Both come from `Welcome.Sketch`, which is measured
/// rather than assumed — see `NSStatusItem.isHiddenFromUser` for what it cost to
/// find out that the obvious answer is wrong.
final class MenuBarSketchView: NSView {

    private static let height: CGFloat = 34

    var sketch: Welcome.Sketch? {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sketch else { return }

        let strip = NSRect(x: 0, y: bounds.height - 22, width: bounds.width, height: 22)
        let path = NSBezierPath(roundedRect: strip, xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if let notch = sketch.notch {
            let rect = NSRect(x: strip.minX + notch.lowerBound * strip.width,
                              y: strip.minY,
                              width: (notch.upperBound - notch.lowerBound) * strip.width,
                              height: strip.height)
            let cut = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -2),
                                   xRadius: 4, yRadius: 4)
            // Black, and **not** `labelColor`. The first version used the label
            // colour at 55%, which is a sensible-looking choice that inverts
            // with the theme: in Dark Mode it came out as a pale block sitting
            // on a dark strip, so the one part of the picture that is a *hole*
            // was the brightest thing in it. A notch is missing screen, and
            // missing screen is black in both themes.
            NSColor.black.withAlphaComponent(0.85).setFill()
            cut.fill()
            NSColor.separatorColor.setStroke()
            cut.lineWidth = 1
            cut.stroke()
        }

        guard sketch.iconIsVisible, let icon = sketch.icon else { return }

        let centre = strip.minX + (icon.lowerBound + icon.upperBound) / 2 * strip.width
        let mark = NSRect(x: centre - 11, y: strip.midY - 8, width: 22, height: 16)

        let halo = NSBezierPath(roundedRect: mark.insetBy(dx: -5, dy: -4),
                                xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        halo.fill()

        // The same three-zone motif as the menu bar glyph, the app icon and the
        // disk image background, because it is the same object each time.
        let widths: [CGFloat] = [0.25, 0.5, 0.25]
        let gap: CGFloat = 2
        var x = mark.minX
        NSColor.controlAccentColor.setFill()
        for fraction in widths {
            let w = mark.width * fraction - gap * 2 / 3
            NSBezierPath(roundedRect: NSRect(x: x, y: mark.minY, width: w, height: mark.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
            x += w + gap
        }

        // A caret under the mark, so "the highlighted one above" has something
        // to point at. Drawn as a filled triangle rather than the line this
        // started as: a 1.5-point stem hanging off the strip read as a rendering
        // artefact rather than as a pointer.
        let caret = NSBezierPath()
        caret.move(to: NSPoint(x: centre - 5, y: strip.minY - 3))
        caret.line(to: NSPoint(x: centre + 5, y: strip.minY - 3))
        caret.line(to: NSPoint(x: centre, y: strip.minY - 10))
        caret.close()
        NSColor.controlAccentColor.setFill()
        caret.fill()
    }
}

// MARK: - The permission

/// The live row: a coloured dot, a headline, a sentence, and — when there is
/// something to do about it — a button.
///
/// It flips **in place** rather than opening a second window, which is the shape
/// every app in this genre that gets it right converged on independently. The
/// failure it prevents is the one users actually report: *"I toggled it and
/// nothing happened"*. The row is the answer to that, and it costs nothing
/// because the watchdog that feeds it has existed since the first release.
final class PermissionRow: NSView {

    private let dot = NSView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

    /// What the button does. A closure rather than a target/action pair because
    /// the thing it has to reach is the controller, which does not exist yet
    /// when this view is built.
    var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10

        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.target = self
        button.action = #selector(act)

        let text = NSStackView(views: [headline, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [dot, text, button])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            // Nudged down to sit on the headline's baseline rather than on the
            // top of its ascender.
            dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Zonas builds its windows in code") }

    func show(_ readiness: Welcome.Readiness) {
        headline.stringValue = readiness.headline
        detail.stringValue = readiness.detail

        if let title = readiness.action {
            button.title = title
            button.isHidden = false
            // Emphasised only while it is the one thing left to do, which is
            // also the only state where the window has a job.
            button.keyEquivalent = readiness == .denied ? "\r" : ""
        } else {
            button.isHidden = true
            button.keyEquivalent = ""
        }

        let tint: NSColor
        switch readiness {
        case .denied: tint = .systemRed
        case .grantedButDeaf: tint = .systemOrange
        case .working: tint = .systemGreen
        }
        dot.layer?.backgroundColor = tint.cgColor
        layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
    }

    @objc private func act(_ sender: Any?) { onAction?() }
}
