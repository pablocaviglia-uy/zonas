import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var modifierHintItem: NSMenuItem?
    private var shortcutHintItem: NSMenuItem?
    private let shortcuts = ShortcutController()
    private var problemItem: NSMenuItem?
    private var switcherMenu: NSMenu?

    /// Until when to stop trying to put the ⌘Tab switcher back.
    ///
    /// Without it, a pin that cannot be honoured is retried on every ⌘ on the
    /// machine — thousands of times a day, each one a line in the log saying the
    /// same thing, and each failing one a pointer dragged across the desk for
    /// nothing. `.distantFuture` is the pinned monitor being unplugged, which
    /// only a change to the screens can undo and which is exactly what clears
    /// this.
    private var switcherQuietUntil: Date?

    /// Whether a move is in flight. It runs off the main thread, so ⌘ can come
    /// down again in the middle of one.
    private var switcherMoving = false
    private var permissionWatchdog: Timer?
    private var layoutWatcher: LayoutWatcher?
    private let monitor = DragMonitor()
    private let editor = EditorController()
    private let welcome = WelcomeController()

    /// The last thing `setState` was told, so that anything opening the welcome
    /// window later can show the truth without asking the system again.
    private var readiness: Welcome.Readiness = .denied

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no app menu: this lives in the menu bar, like Raycast
        // or Rectangle.
        NSApp.setActivationPolicy(.accessory)

        // Writes the JSON out so it can be edited without having to invent the
        // format, but ONLY if it isn't there yet: overwriting it on every launch
        // wiped the user's zones every time the file had a typo.
        LayoutStore.shared.createIfMissing()

        buildMenu()
        wireTheEditor()
        wireTheWelcome()
        wireTheSwitcher()
        startMonitor()
        startWatchingTheLayout()
        shortcuts.apply(LayoutStore.shared.layout.shortcuts)

        welcome.openIfFirstLaunch(readiness: readiness)
        describeTheIcon()
    }

    /// Re-opening an app that is already running.
    ///
    /// **This is the only way back for somebody who cannot see the menu bar
    /// icon**, and it is the sentence the welcome window is able to print
    /// because of it. Without this, double-clicking Zonas in Applications does
    /// nothing whatsoever — there is no Dock icon to bounce, no window to raise
    /// and no menu to open — so the one instinct everybody has when an app seems
    /// to have vanished leads nowhere. Both Rectangle and BetterDisplay point
    /// their users at exactly this for exactly this reason.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Log.write("welcome: opened again from the Finder")
        welcome.open(readiness: readiness)
        describeTheIcon()
        return true
    }

    private func wireTheWelcome() {
        welcome.onGrantPermission = { [weak self] in self?.openPermissions() }
        welcome.onToggleLaunchAtLogin = { [weak self] on in
            LaunchAtLogin.set(on)
            self?.launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    /// Tells the welcome window where the menu bar icon ended up, a second after
    /// being asked.
    ///
    /// The delay is not politeness. `occlusionState` — the only signal that
    /// tells the truth about whether macOS is drawing a status item — reports a
    /// perfectly visible icon as hidden for the first ~80 ms of its life, and
    /// takes about three quarters of a second to settle after the bar changes.
    /// Both were measured. Asking immediately would tell every fresh install
    /// that its icon is missing, which is the one thing this section exists to
    /// get right.
    private func describeTheIcon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let screen = self.statusItem?.button?.window?.screen ?? NSScreen.main
            self.welcome.showIcon(self.statusItem, on: screen)
            if self.statusItem?.isHiddenFromUser == true {
                // Rule 9. Not a refusal, but the same shape: from outside the
                // app "there is no icon" and "the app did not start" are the
                // same picture.
                Log.write("menu bar: macOS is not drawing our icon — the bar is full")
            }
        }
    }

    /// The one rule that neither the editor nor the drag monitor can hold on its
    /// own: **they cannot both be listening.**
    ///
    /// With the tap live, holding the modifier inside the editor summons the
    /// drag overlay, which draws the same zones at `.popUpMenu` over the ones
    /// you are editing at `.floating` — and since the editor's own gestures use
    /// modifiers too, that is not an edge case, it is every other click.
    ///
    /// It lives here because it is a fact about the app rather than about either
    /// component, and because this is the file where you would come looking for
    /// it. Neither of them refers to the other.
    private func wireTheEditor() {
        editor.onVisibilityChange = { [weak self] isOpen in
            self?.monitor.setEnabled(!isOpen)
        }
    }

    // MARK: - The ⌘Tab switcher's screen

    /// Wires the pin to the one moment it is worth honouring.
    ///
    /// **The correction happens when ⌘ goes down, and that is the whole
    /// design.** The obvious alternative is to watch where the Dock is and put
    /// it back the moment it drifts, and it is wrong twice. Moving it means
    /// dragging the pointer to the bottom of another screen, so "the moment it
    /// drifts" means doing that the instant somebody has deliberately pushed
    /// their cursor to the bottom of the screen they are working on — fighting
    /// them, over the thing they just did. And a Dock on the wrong screen costs
    /// nothing at all until the switcher is opened.
    ///
    /// ⌘ going down is the last moment before that and the first moment anybody
    /// cares. The check that finds nothing owed — which is almost every ⌘ — is
    /// one description of one window.
    ///
    /// It is also why nothing here runs on a timer or waits for the displays to
    /// settle after a wake. Reconfiguration is one of the two ways this drifts,
    /// and the answer is not to race it: the next ⌘ finds the Dock on the wrong
    /// screen and moves it, well before anybody has finished pressing ⌘Tab.
    private func wireTheSwitcher() {
        monitor.onCommand = { [weak self] in self?.keepTheSwitcherPut() }

        // The one thing a change of screens does: let it be tried again. A pin
        // to a monitor that is not plugged in gives up permanently, and this is
        // the only event that can make it plugged in.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.switcherQuietUntil = nil
            }
    }

    /// How many attempts in a row have failed, which is what sets how long to
    /// wait before the next one.
    ///
    /// The wait doubles from one second to thirty, because the two things that
    /// make this fail want opposite answers. A menu or the switcher itself being
    /// open swallows the walk, and that is over by the next keystroke — waiting
    /// half a minute on it would leave the switcher on the wrong screen for the
    /// rest of the minute somebody is actually using it. A Dock that will not
    /// move at all is not going to move on the next keystroke either, and
    /// retrying it forever writes the same line into the log all day.
    private var switcherFailures = 0

    private var switcherBackOff: TimeInterval {
        min(30, pow(2, Double(max(switcherFailures - 1, 0))))
    }

    private func keepTheSwitcherPut() {
        // Posting the walk is quick, but waiting for the Dock is up to a second,
        // and it all runs off the main thread — so ⌘ can perfectly well come
        // down again while one is in flight. A second gesture layered on the
        // first would walk the pointer twice.
        guard !switcherMoving else { return }
        guard let pinned = Switcher.pinned() else { return }
        guard let current = DockDisplay.current.flatMap(DockDisplay.uuid(of:)) else { return }
        guard Switcher.shouldCorrect(pinned: pinned, current: current) else { return }
        if let quietUntil = switcherQuietUntil, Date() < quietUntil { return }

        // Asked here as well as inside `move`, because this is the path that
        // runs on every ⌘: without it the refusal is a log line every thirty
        // seconds for as long as the pin stands. Somebody who moves their Dock
        // back to the bottom picks the screen again from the menu, which clears
        // this — the same way an unplugged monitor does.
        guard Switcher.Edge.current == .bottom else {
            Log.write("switcher: the Dock is on the \(Switcher.Edge.current.rawValue), "
                      + "which cannot be moved between screens — the pin is on hold")
            switcherQuietUntil = .distantFuture
            return
        }

        guard let screen = DockDisplay.screen(pinned) else {
            // Rule 9's shape: from outside, a pin to a monitor that is at the
            // office and a pin that silently does nothing look identical.
            Log.write("switcher: pinned to a screen that is not connected — "
                      + "leaving it alone until the screens change")
            switcherQuietUntil = .distantFuture
            return
        }

        switcherMoving = true
        DockDisplay.move(to: screen) { [weak self] landed in
            guard let self else { return }
            self.switcherMoving = false
            if landed {
                self.switcherFailures = 0
            } else {
                self.switcherFailures += 1
                self.switcherQuietUntil = Date().addingTimeInterval(self.switcherBackOff)
            }
        }
    }

    /// The submenu, rebuilt from scratch every time it is about to be seen.
    ///
    /// Not patched in place: the items *are* the monitors plugged in at this
    /// instant, and `NSScreen` instances do not survive a reconfiguration —
    /// `Coords` says why — so there is nothing worth keeping between openings.
    private func rebuildSwitcherMenu() {
        guard let menu = switcherMenu else { return }
        menu.removeAllItems()

        let names = screenNames()
        guard let current = DockDisplay.current.flatMap(DockDisplay.uuid(of:)) else {
            // No choices at all rather than choices that would not work. The pin
            // is honoured by reading the Dock's screen back, so without it every
            // item in this menu would be a switch wired to nothing.
            let explanation = NSMenuItem(title: "Cannot tell where the Dock is",
                                         action: nil, keyEquivalent: "")
            explanation.isEnabled = false
            menu.addItem(explanation)
            return
        }

        // Where it is right now, in the same voice as the modifier reminder at
        // the top of the main menu: a line you read, not a thing you click. It
        // is also the only way to tell an unpinned switcher that happens to be
        // in the right place from a pinned one.
        let now = NSMenuItem(title: "Now on \(names[current] ?? "an unknown screen")",
                             action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)

        // Said here rather than left as a menu that quietly does nothing. The
        // switcher follows the Dock, and a Dock at the side of the screen cannot
        // be moved between screens at all — `Switcher.Edge` has the nine
        // attempts.
        guard Switcher.Edge.current == .bottom else {
            let why = NSMenuItem(title: "Needs the Dock at the bottom of the screen",
                                 action: nil, keyEquivalent: "")
            why.isEnabled = false
            menu.addItem(why)
            return
        }
        menu.addItem(.separator())

        let pinned = Switcher.pinned()
        let anywhere = ownItem("Wherever the Dock Is", #selector(pinSwitcher))
        anywhere.state = pinned == nil ? .on : .off
        menu.addItem(anywhere)

        for screen in NSScreen.screens {
            guard let uuid = DockDisplay.uuid(of: screen) else { continue }
            let item = ownItem(names[uuid] ?? screen.localizedName, #selector(pinSwitcher))
            item.representedObject = uuid
            item.state = pinned == uuid ? .on : .off
            menu.addItem(item)
        }
    }

    /// A name per display UUID, made unambiguous.
    ///
    /// `localizedName` is the model, so the second identical monitor on a desk
    /// is a menu with the same word in it twice and no way to tell which is
    /// which. The size is what `zonas monitors` prints, for the same reason.
    private func screenNames() -> [String: String] {
        let screens = NSScreen.screens
        var counts: [String: Int] = [:]
        for screen in screens { counts[screen.localizedName, default: 0] += 1 }

        var names: [String: String] = [:]
        for screen in screens {
            guard let uuid = DockDisplay.uuid(of: screen) else { continue }
            let name = screen.localizedName
            names[uuid] = counts[name, default: 0] > 1
                ? "\(name) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))"
                : name
        }
        return names
    }

    /// Picking a screen pins it **and moves the switcher there now**.
    ///
    /// Moving it immediately is the point of the menu item. Somebody opens this
    /// because the switcher is on the wrong screen right now; a setting that
    /// only took effect at the next ⌘ would read as a menu item that did
    /// nothing, since the next ⌘ is usually the ⌘ of the ⌘Tab they were
    /// reaching for.
    @objc private func pinSwitcher(_ sender: NSMenuItem) {
        let uuid = sender.representedObject as? String
        Switcher.pin(uuid)
        switcherQuietUntil = nil
        switcherFailures = 0

        guard let uuid else {
            Log.write("switcher: unpinned — back to wherever the Dock is")
            return
        }
        guard let screen = DockDisplay.screen(uuid) else { return }
        Log.write("switcher: pinned to \(screen.localizedName)")

        // **Not moved here.** A menu action runs while the menu is still being
        // taken down, and a menu that is coming down still owns the mouse: the
        // pointer walk this posts goes into the tracking session and out the
        // other side, and the Dock never hears about it. Measured, and it fails
        // silently — the pin is recorded, the log says the Dock stayed put, and
        // from the outside the menu item simply did not work.
        switcherPending = uuid
    }

    /// What the menu asked for, waiting for the menu to be gone.
    ///
    /// The UUID and not the `NSScreen`. It is only held for a tenth of a second,
    /// but `NSScreen` instances are replaced wholesale on any reconfiguration —
    /// `Coords` says why — and a monitor going to sleep inside that tenth of a
    /// second would leave a dead object to read a frame off.
    private var switcherPending: String?

    /// How long after the menu closes to move the Dock.
    ///
    /// `menuDidClose` is sent while the tracking session is still unwinding, so
    /// it is the right moment to *know* and the wrong moment to act. A tenth of
    /// a second was the shortest delay that worked every time.
    private static let afterTheMenu: TimeInterval = 0.1

    func menuDidClose(_ menu: NSMenu) {
        // Cleared whatever happens next. Left set, a request that could not be
        // served now is served by the *next* time the menu is closed, which
        // could be minutes later and about something else entirely.
        let pending = switcherPending
        switcherPending = nil

        guard let pending else { return }
        guard !switcherMoving, let screen = DockDisplay.screen(pending) else {
            // Rule 9. The pin itself is already written, so the next ⌘ serves
            // it — but "I picked a screen and nothing happened" needs a line
            // saying which of the two reasons it was.
            Log.write(switcherMoving
                      ? "switcher: a move was already under way — the pin stands, the next ⌘ serves it"
                      : "switcher: the screen just picked is no longer connected")
            return
        }
        switcherMoving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterTheMenu) { [weak self] in
            DockDisplay.move(to: screen) { [weak self] _ in self?.switcherMoving = false }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        layoutWatcher?.stop()
    }

    /// Edit the file, save, and the zones change. Without this the file is an
    /// import format with a menu item next to it.
    ///
    /// "Reload Zones" stays in the menu regardless: it costs nothing, and it is
    /// the thing to reach for when you want to know whether the file is being
    /// read at all.
    private func startWatchingTheLayout() {
        let url = LayoutStore.shared.fileURL
        let watcher = LayoutWatcher(url: url) { [weak self] in
            switch LayoutStore.shared.reload() {
            case .changed:
                // The settings are in the line because changing only `gap` is a
                // real edit that would otherwise log the same words as changing
                // nothing, and leave you wondering whether it took.
                let layout = LayoutStore.shared.layout
                Log.write("layout: reloaded — \"\(layout.name)\", \(layout.zones.count) zones, "
                          + "gap \(Int(layout.gap)), margin \(Int(layout.margin)), "
                          + "maximise \(Int(layout.maximise)), "
                          + "\(layout.modifier.symbol)")
                self?.shortcuts.apply(layout.shortcuts)
            case .unchanged, .failed:
                // A save that changed nothing is not worth a line, and a save
                // that broke the file already logged why, with the line number.
                break
            }
            self?.showProblem(LayoutStore.shared.problem)
            // The editor draws whatever the store holds, so a save made from
            // vim on the other screen moves the zones underneath it. Without
            // this the editor would keep showing the layout it opened with,
            // which is the one thing this app has spent a stage promising not
            // to do.
            self?.editor.refresh()
            // The welcome window names the modifier and draws the zones, and
            // both of those are in the file that just changed.
            self?.welcome.refresh()
        }
        watcher.start()
        layoutWatcher = watcher
        Log.write("watch: following \(url.path)")
    }

    // MARK: - Permissions

    /// Asks for the Accessibility permission, which is what enables moving other
    /// apps' windows.
    private func startMonitor() {
        // No prompt here. When the app launches on its own at login, a modal
        // system dialog would show up while the session is still coming up: it
        // steals focus or ends up buried behind the Desktop. The explicit request
        // lives in the menu's "Accessibility Permissions…" item, which is when
        // the user actually asked for it.
        let trusted = AXIsProcessTrusted()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.write("startup: Zonas \(version) (build \(build))")
        Log.write("startup: signature \(signatureFingerprint())")
        Log.write("startup: accessibility permission = \(trusted ? "YES" : "NO")")
        Log.write("startup: login item = \(LaunchAtLogin.statusText)")

        if trusted, monitor.start() {
            setState(.working)
            return
        }
        // Two different failures, and they were the same call until now.
        // `trusted` and the tap coming up are separate questions and the second
        // one is the one that decides whether anything works — see
        // `Welcome.Readiness`.
        setState(Welcome.Readiness(trusted: trusted, tapIsLive: false))
        waitForPermission()
    }

    /// Waits for the permission to be granted, polling every so often.
    ///
    /// The system dialog shows up **only once** per app. If it went unnoticed
    /// —or the permission was granted later from Settings— the app has to find
    /// out on its own.
    ///
    /// `AXIsProcessTrusted()` caches inside the process, but that cache is
    /// invalidated on every change to the TCC database, so the timer really does
    /// ask again on the following tick. Measured: between two changes the timer
    /// ticked ~180 times without producing a single query to the system, and it
    /// answered 1.5 s after the switch was flipped.
    private func waitForPermission() {
        permissionWatchdog?.invalidate()
        var attempts = 0

        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { return }

            attempts += 1
            // Heartbeat every 30 s. Without it, a live timer and a dead one read
            // the same in the log: silence. That was exactly the blind spot that
            // took five minutes to investigate.
            if attempts % 20 == 0 {
                Log.write("waiting for permission: \(attempts) checks, still denied")
            }
            guard AXIsProcessTrusted() else { return }

            Log.write("permission: granted, starting the monitor")
            let started = self.monitor.start()
            self.setState(Welcome.Readiness(trusted: true, tapIsLive: started))

            // Watching only stops if the tap really came up alive. TCC can flip
            // the bit an instant before the tap subsystem honors it: if the
            // watchdog were torn down here, the log would say "granted", the tap
            // would be dead and there would never be another retry.
            guard started else { return }
            timer.invalidate()
            self.permissionWatchdog = nil
        }
    }

    /// The one place that knows whether Zonas can do anything, and everything
    /// that has to show it.
    ///
    /// The menu bar icon looks dimmed while it cannot, so it is visible that the
    /// app is alive and unable to act. The tooltip used to say "the Accessibility
    /// permission is missing" for both failures, which is a lie in one of them
    /// and sends the reader to turn on a switch that is already on.
    private func setState(_ readiness: Welcome.Readiness) {
        self.readiness = readiness

        statusItem?.button?.appearsDisabled = !readiness.isWorking
        statusItem?.button?.toolTip = readiness.isWorking
            ? "Zonas: \(modifierHint.prefix(1).lowercased() + modifierHint.dropFirst())"
            : "Zonas: \(readiness.headline.prefix(1).lowercased() + readiness.headline.dropFirst())"

        // The window is told rather than asking, which is what keeps it from
        // growing a second poller 1.5 s out of phase with this one.
        welcome.update(readiness)
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1",
                                     accessibilityDescription: "Zonas")

        let menu = NSMenu()
        menu.delegate = self
        let hint = NSMenuItem(title: modifierHint, action: nil, keyEquivalent: "")
        modifierHintItem = hint
        menu.addItem(hint)
        let keys = NSMenuItem(title: shortcutHint, action: nil, keyEquivalent: "")
        shortcutHintItem = keys
        menu.addItem(keys)

        // Hidden unless the file is broken. It is above the separator, where the
        // eye goes first, and clicking it opens the file at the problem rather
        // than opening the log and making you find it.
        let problem = ownItem("", #selector(openLayout))
        problem.isHidden = true
        problemItem = problem
        menu.addItem(problem)

        menu.addItem(.separator())
        menu.addItem(ownItem("Edit Zones…", #selector(openEditor)))
        // This used to be the item called "Edit Zones…", and the rename is the
        // point: with a visual editor in the menu next to it, an item that opens
        // a text file has to say so or half the people who click it get a
        // surprise and the other half never find the file.
        menu.addItem(ownItem("Edit the File…", #selector(openLayout)))
        menu.addItem(ownItem("Reload Zones", #selector(reloadLayout), key: "r"))
        menu.addItem(ownItem("Open Log…", #selector(openLog)))
        menu.addItem(.separator())

        // A submenu and not a row of items, because the list is however many
        // monitors are plugged in and it changes while the app is running.
        let switcher = NSMenuItem(title: "App Switcher Screen", action: nil, keyEquivalent: "")
        let switcherChoices = NSMenu()
        switcher.submenu = switcherChoices
        switcherMenu = switcherChoices
        menu.addItem(switcher)

        let launchItem = ownItem("Launch at Login", #selector(toggleLaunchAtLogin))
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)

        menu.addItem(ownItem("Accessibility Permissions…", #selector(openPermissions)))
        // The welcome window opens itself once and then never again, which is
        // right — and would strand the person who closed it before reading it,
        // which is not. One line buys the way back.
        menu.addItem(ownItem("Welcome to Zonas…", #selector(openWelcome)))
        menu.addItem(.separator())

        // No target: the action has to travel up the responder chain to NSApp,
        // which is the one that knows how to do `terminate:`. Pointing it at the
        // AppDelegate —which does not respond to that selector— makes macOS draw
        // the item disabled, which is exactly the bug it used to have.
        menu.addItem(NSMenuItem(title: "Quit Zonas",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    /// Item whose action this delegate handles.
    private func ownItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openLayout() {
        NSWorkspace.shared.open(LayoutStore.shared.fileURL)
    }

    @objc private func openEditor() {
        editor.open()
    }

    @objc private func openWelcome() {
        welcome.open(readiness: readiness)
        describeTheIcon()
    }

    /// Here an alert **is** right, and the difference is who asked.
    ///
    /// The watcher reloads because you saved, so it reports by changing the icon
    /// and gets out of the way. You picking "Reload Zones" is a question, and a
    /// question deserves an answer — silence would leave you unable to tell a
    /// successful reload from a menu item that does nothing.
    @objc private func reloadLayout() {
        switch LayoutStore.shared.reload() {
        case .changed, .unchanged:
            shortcuts.apply(LayoutStore.shared.layout.shortcuts)
            showProblem(nil)
        case .failed:
            showProblem(LayoutStore.shared.problem)
            let alert = NSAlert()
            alert.messageText = "That layout file cannot be read"
            alert.informativeText = (LayoutStore.shared.problem ?? "")
                + "\n\nThe zones you were using are still in place, and the file "
                + "has not been touched."
            // An .accessory app gets a generic icon in its own alerts unless it
            // is told otherwise, which makes the dialog look like it belongs to
            // no application at all.
            alert.icon = NSApp.applicationIconImage
            alert.addButton(withTitle: "Edit the File")
            alert.addButton(withTitle: "Later")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openLayout() }
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLoginItem?.state = LaunchAtLogin.set(!LaunchAtLogin.isEnabled) ? .on : .off
    }

    /// The checkmark is re-read every time the menu opens. If the user turns the
    /// login item off from Settings no notification arrives and there is no KVO,
    /// so asking when it opens is the cheap way to avoid lying.
    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        // The modifier comes from the file and the file can change under us, so
        // the reminder is re-read rather than baked in when the menu was built.
        modifierHintItem?.title = modifierHint
        shortcutHintItem?.title = shortcutHint
        shortcutHintItem?.isHidden = LayoutStore.shared.layout.shortcuts == nil
        showProblem(LayoutStore.shared.problem)
        // The submenu has no delegate of its own on purpose: this fires before
        // the main menu is drawn, which is well before anybody has moved the
        // pointer down to open it.
        rebuildSwitcherMenu()
    }

    /// Puts what is wrong with the file where somebody will see it.
    ///
    /// Not an alert. You break the file by saving it half-edited, which happens
    /// several times a minute while you are working on it, and a modal dialog
    /// every time would make the live reload unbearable — it would be the app
    /// interrupting you to report something you already know and are in the
    /// middle of fixing. The menu bar icon and one line in the menu are loud
    /// enough to notice and quiet enough to ignore.
    private func showProblem(_ problem: String?) {
        problemItem?.isHidden = problem == nil
        problemItem?.title = problem.map { "⚠︎ \($0)" } ?? ""

        // The icon changes shape, not just colour: on a busy menu bar a
        // recoloured glyph at 16 points is not something anybody notices.
        statusItem?.button?.image = NSImage(
            systemSymbolName: problem == nil ? "rectangle.split.3x1" : "exclamationmark.triangle",
            accessibilityDescription: problem == nil ? "Zonas" : "Zonas: the layout file has an error")
    }

    /// The one line of instructions the app itself gives, so it has to carry
    /// both keys — the menu is where somebody looks when they have forgotten
    /// how this works, and a reminder that only tells half the story is how a
    /// feature stays undiscovered.
    ///
    /// The order is the instruction, not decoration: **drag first, then add the
    /// span key.** On macOS ⌃ with the mouse button is the secondary click, so
    /// pressing it before the button turns the whole gesture into a right-click
    /// and nothing happens at all.
    private var modifierHint: String {
        let layout = LayoutStore.shared.layout
        let key = layout.modifier.symbol
        let drag = "Drag a window with \(key), let \(key) go to place it"
        guard let span = layout.span else { return drag }
        return "\(drag) — \(span.symbol) covers several zones"
    }

    /// The second line of instructions, for the keyboard. Hidden rather than
    /// blank when the file has turned the keys off: an empty menu item looks
    /// like a bug.
    private var shortcutHint: String {
        guard let chord = LayoutStore.shared.layout.shortcuts else { return "" }
        return "\(chord.symbol) with an arrow moves the front window — "
            + "\(chord.symbol)↩ fills the screen, \(chord.symbol)Z places it"
    }

    /// Leaves the item greyed out in the `.build/` copy. Without this `NSMenu`
    /// would enable it anyway, because the target responds to the selector — and
    /// touching it from there would leave the login item pointing at an ephemeral
    /// bundle.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item === launchAtLoginItem ? LaunchAtLogin.isInstalledCopy : true
    }

    @objc private func openPermissions() {
        // Here the system dialog is the right call: the user asked for it.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
