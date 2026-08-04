import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var modifierHintItem: NSMenuItem?
    private var problemItem: NSMenuItem?
    private var permissionWatchdog: Timer?
    private var layoutWatcher: LayoutWatcher?
    private let monitor = DragMonitor()
    private let editor = EditorController()

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
        startMonitor()
        startWatchingTheLayout()
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
                          + "\(layout.modifier.symbol)")
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
            setActive(true)
            return
        }
        setActive(false)
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
            self.setActive(started)

            // Watching only stops if the tap really came up alive. TCC can flip
            // the bit an instant before the tap subsystem honors it: if the
            // watchdog were torn down here, the log would say "granted", the tap
            // would be dead and there would never be another retry.
            guard started else { return }
            timer.invalidate()
            self.permissionWatchdog = nil
        }
    }

    /// The menu bar icon looks dimmed while the permission is missing, so it is
    /// visible that the app is alive but cannot do anything.
    private func setActive(_ isActive: Bool) {
        statusItem?.button?.appearsDisabled = !isActive
        statusItem?.button?.toolTip = isActive
            ? "Zonas: hold \(LayoutStore.shared.layout.modifier.symbol) while dragging a window"
            : "Zonas: the Accessibility permission is missing"
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

        let launchItem = ownItem("Launch at Login", #selector(toggleLaunchAtLogin))
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)

        menu.addItem(ownItem("Accessibility Permissions…", #selector(openPermissions)))
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

    /// Here an alert **is** right, and the difference is who asked.
    ///
    /// The watcher reloads because you saved, so it reports by changing the icon
    /// and gets out of the way. You picking "Reload Zones" is a question, and a
    /// question deserves an answer — silence would leave you unable to tell a
    /// successful reload from a menu item that does nothing.
    @objc private func reloadLayout() {
        switch LayoutStore.shared.reload() {
        case .changed, .unchanged:
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
        showProblem(LayoutStore.shared.problem)
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

    private var modifierHint: String {
        "Hold \(LayoutStore.shared.layout.modifier.symbol) while dragging a window"
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
