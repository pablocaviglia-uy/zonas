import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var permissionWatchdog: Timer?
    private let monitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no app menu: this lives in the menu bar, like Raycast
        // or Rectangle.
        NSApp.setActivationPolicy(.accessory)

        // Writes the JSON out so it can be edited without having to invent the
        // format, but ONLY if it isn't there yet: overwriting it on every launch
        // wiped the user's zones every time the file had a typo.
        ZoneStore.shared.createIfMissing()

        buildMenu()
        startMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
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
            ? "Zonas: hold ⇧ while dragging a window"
            : "Zonas: the Accessibility permission is missing"
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1",
                                     accessibilityDescription: "Zonas")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Hold ⇧ while dragging a window",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(ownItem("Edit Zones (JSON)…", #selector(openLayout)))
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
        NSWorkspace.shared.open(ZoneStore.shared.fileURL)
    }

    @objc private func reloadLayout() {
        ZoneStore.shared.reload()
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
