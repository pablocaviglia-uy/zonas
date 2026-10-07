import AppKit
import AVFoundation
import ApplicationServices

/// A disposable personal calibration. Nothing is persisted or enabled at launch.
final class GazeExperimentController: NSObject, NSWindowDelegate {
    private let camera = GazeCamera()
    private var window: NSWindow?
    private var overlay: GazeCalibrationWindow?
    private let status = NSTextField(wrappingLabelWithString: "Camera off. Start explicitly to run the experiment.")
    private let report = NSTextField(wrappingLabelWithString: "No calibration yet. A successful test enables an advisory mark in ⌥Tab.")
    private let cameraChoice = NSPopUpButton()
    private let screenChoice = NSPopUpButton()
    private let startButton = NSButton()
    private let stopButton = NSButton()
    private let calibrateButton = NSButton()
    private let retestButton = NSButton()
    private let monitor = GazeMonitorView()
    private let screenMarker = GazeScreenMarker()
    private let markerButton = NSButton(checkboxWithTitle: "Show gaze on screen (click-through)", target: nil, action: nil)
    private let fixationProgress = NSProgressIndicator()
    private let lastShortcut = NSTextField(wrappingLabelWithString: "Last ⌥Tab: not tried yet. Look at a window before pressing the shortcut.")
    private var liveTimer: Timer?
    private var latestEstimate: CGPoint?
    private var hasFeatures = false
    private var switcherOpen = false
    private var inventory = Inventory()
    private var inventoryBusy = false
    private var inventoryEpoch = 0
    private var lastInventoryRequest = 0.0
    private var devices: [AVCaptureDevice] = []
    private var displays: [NSScreen] = []
    private var running = false
    private var starting = false
    private var model: Gaze.Model?
    private var validation: Gaze.Validation?
    private var training: [Gaze.Group] = []
    private var calibratedDisplay: CGDirectDisplayID?
    private var calibratedFrame: CGRect?
    private var fixation = Gaze.Fixation()
    private var timer: Timer?
    private var targets: [CGPoint] = []
    private var groups: [Gaze.Group] = []
    private var collector = Gaze.Collector(began: 0)
    private var targetIndex = 0
    private var targetBegan = 0.0
    private var testingOnly = false
    private var lastStatusUpdate = 0.0
    private var lastSample = 0.0
    private var sampleInterval = 0.0
    private var lastCameraMessage = "Waiting for a camera frame"
    private var watchdog: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var cameraObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        camera.onState = { [weak self] on, message in
            guard let self else { return }
            self.running = on
            if on { self.lastSample = ProcessInfo.processInfo.systemUptime }
            self.starting = !on && (message.hasPrefix("Starting") || message.hasPrefix("Waiting"))
            self.status.stringValue = message
            self.lastCameraMessage = message
            Log.write("gaze POC: camera state — \(message)")
            if !on { self.clearCalibration() }
            self.updateButtons()
        }
        camera.onSample = { [weak self] features, message, time in
            self?.receive(features, message: message, at: time)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.status.stringValue = "Displays changed. Start again and recalibrate."
            self?.refreshChoices()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                           queue: .main) { [weak self] notification in
                guard let self else { return }
                let selected = self.devices.indices.contains(self.cameraChoice.indexOfSelectedItem)
                    ? self.devices[self.cameraChoice.indexOfSelectedItem].uniqueID : nil
                if name == AVCaptureDevice.wasDisconnectedNotification,
                   let device = notification.object as? AVCaptureDevice, device.uniqueID == selected {
                    self.stop()
                    self.status.stringValue = "Selected camera disconnected. Choose another camera and recalibrate."
                }
                self.refreshCameras()
                self.updateButtons()
            })
        }
    }

    func open() {
        if window == nil { makeWindow() }
        if !running && !starting { refreshChoices() }
        // The experiment's controls belong on the laptop; the calibration
        // overlay goes only to the display the person explicitly selects.
        guard let builtIn = NSScreen.screens.first(where: { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }) else {
            Log.write("gaze POC: built-in screen unavailable — controls were not opened")
            return
        }
        let area = builtIn.visibleFrame
        let size = window?.frame.size ?? .zero
        window?.setFrameOrigin(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        guard window?.screen?.displayID == builtIn.displayID else {
            Log.write("gaze POC: could not place controls on the built-in screen")
            return
        }
        Log.write("gaze POC: controls on built-in display \(builtIn.displayID ?? 0)")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateLiveTimer()
    }

    /// Draw the real controls off-screen for internal QA; never starts capture
    /// or orders a window onto either display.
    func writeDiagnostics(to directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        makeWindow()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func render(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DiagnosticError.render }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DiagnosticError.render }
            try png.write(to: directory.appendingPathComponent(name))
        }
        if let content = window?.contentView {
            for (appearance, name) in [(NSAppearance.Name.aqua, "controls-light.png"), (.darkAqua, "controls-dark.png")] {
                content.appearance = NSAppearance(named: appearance)
                try render(content, name: name)
            }
            report.stringValue = "TEST PASSED · advisory hints enabled\nRegions: 6/6 · valid predictions: 100%\nMedian error: 4.5% · P90: 8.9% of normalized screen\nConservative error box: ±230 × 85 pt (245 pt diagonal).\nLook at a visible window, then hold ⌥Tab. A mint dot marks the estimate; keys and clicks still choose."
            status.stringValue = "Camera on · Both pupils detected · 15 frames/s (synthetic UI fixture)"
            let display = CGRect(x: -1728, y: -1117, width: 1728, height: 1117)
            monitor.snapshot = GazeMonitorView.Snapshot(
                displayBounds: display,
                windows: [Gaze.Window(id: 2, bounds: CGRect(x: -790, y: -1090, width: 760, height: 1060)),
                          Gaze.Window(id: 1, bounds: CGRect(x: -1700, y: -1090, width: 880, height: 1060))],
                estimate: CGPoint(x: 0.3, y: 0.45), stablePoint: CGPoint(x: 0.31, y: 0.44),
                errorRadius: CGSize(width: 0.05, height: 0.07), candidateID: 1,
                windowLabels: [1: "Chrome · Video", 2: "Claude"],
                headline: "Candidate: Chrome · Video",
                detail: "Hold ⌥Tab now to mark this window. Gaze suggests; keys and clicks still choose.")
            fixationProgress.doubleValue = 100
            lastShortcut.stringValue = "Last ⌥Tab: Candidate: Chrome · Video. This was the gaze at the opening shortcut; keys and clicks still choose."
            try render(content, name: "controls-report.png")
            content.appearance = NSAppearance(named: .aqua)
            try render(content, name: "controls-live-light.png")
            let marker = GazeMarkerView(frame: CGRect(x: 0, y: 0, width: 1200, height: 700))
            marker.snapshot = monitor.snapshot
            try render(marker, name: "screen-marker-candidate.png")
            marker.snapshot.estimate = nil; marker.snapshot.stablePoint = nil; marker.snapshot.candidateID = nil
            marker.snapshot.headline = "Eyes unavailable · Both pupils must be detected"
            try render(marker, name: "screen-marker-eyes-lost.png")
            content.appearance = NSAppearance(named: .darkAqua)
            monitor.snapshot.estimate = CGPoint(x: 0.52, y: 0.45)
            monitor.snapshot.stablePoint = CGPoint(x: 0.53, y: 0.44)
            monitor.snapshot.candidateID = nil
            monitor.snapshot.headline = "Uncertain between windows"
            monitor.snapshot.detail = "The dashed error margin crosses a window edge or another window. Look farther inside a large visible window."
            try render(content, name: "controls-live-uncertain-dark.png")
            clearCalibration()
        }
        let target = GazeTargetView(frame: CGRect(x: 0, y: 0, width: 1200, height: 500))
        target.target = CGPoint(x: 0.08, y: 0.08)
        target.caption = "Calibration · 1/9 · Look at the dot\nUsable pupil samples: 0/18 · 5.5 s left\nNo face detected\nKeep your normal posture · Esc cancels"
        try render(target, name: "calibration.png")
        print("Off-screen UI snapshots: \(directory.path)")
        print("Cameras discovered: \(devices.count); capture was not started.")
    }

    private enum DiagnosticError: Error { case render }

    @objc func stop() {
        camera.stop()
        running = false; starting = false
        watchdog?.invalidate(); watchdog = nil
        clearCalibration()
        status.stringValue = "Camera off. Calibration discarded."
        updateButtons()
    }

    /// Called once at the opening key press, before previews cover the desktop.
    func suggestion(eligible: Set<CGWindowID>, at now: Double) -> CGWindowID? {
        guard running else { return nil }
        // This is the exact pre-carousel geometry and eligibility used for the
        // advisory mark, not the monitor's periodically refreshed approximation.
        let fresh = Self.readInventory(ignoring: screenMarker.windowID)
        inventoryEpoch += 1
        inventory = fresh
        var snapshot = liveSnapshot(at: now, inventory: fresh, eligible: eligible)
        if snapshot.candidateID != nil {
            snapshot.detail = "This was the gaze at the opening shortcut. The mint mark identifies the suggestion; keys and clicks still choose."
        }
        lastShortcut.stringValue = "Last ⌥Tab: \(snapshot.headline). \(snapshot.detail)"
        snapshot.headline = "⌥Tab snapshot · " + snapshot.headline
        monitor.snapshot = snapshot
        switcherOpen = true
        screenMarker.hide()
        updateLiveTimer()
        return snapshot.candidateID
    }

    func switcherEnded() {
        switcherOpen = false
        updateLiveTimer()
    }

    func windowWillClose(_ notification: Notification) { updateLiveTimer(closing: true) }

    @objc private func markerChanged() { updateLiveTimer(); refreshLive() }

    private struct Inventory {
        var collectedAt = 0.0
        var windows: [Gaze.Window] = []
        var labels: [CGWindowID: String] = [:]
        var eligible: Set<CGWindowID> = []
    }

    private static func readInventory(ignoring markerID: CGWindowID?) -> Inventory {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let cached = WindowSwitcherController.cachedGazeWindows()
        var result = Inventory()
        result.collectedAt = ProcessInfo.processInfo.systemUptime
        for row in info {
            guard (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let pid = row[kCGWindowOwnerPID as String] as? pid_t ?? 0
            // Ignore only this diagnostic drawing. Controls and other floating
            // windows remain real occluders, including our own control panel.
            if id == markerID && pid == getpid() { continue }
            result.windows.append(Gaze.Window(id: id, bounds: rect))
            let owner = row[kCGWindowOwnerName as String] as? String ?? "Window"
            let metadata = cached.first { $0.id == id && $0.pid == pid }
            result.labels[id] = metadata.map { $0.title.isEmpty ? owner : "\(owner) · \($0.title)" } ?? owner
            if metadata != nil, (row[kCGWindowLayer as String] as? Int ?? 0) == 0 {
                result.eligible.insert(id)
            }
        }
        return result
    }

    private func updateLiveTimer(closing: Bool = false) {
        liveTimer?.invalidate(); liveTimer = nil
        let visible = !closing && window?.isVisible == true
        if running && overlay == nil && !switcherOpen && (visible || markerButton.state == .on) {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshLive() }
            RunLoop.main.add(timer, forMode: .common); liveTimer = timer
        } else { screenMarker.hide() }
        if !switcherOpen { refreshLive() }
    }

    private func refreshLive() {
        guard !switcherOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        monitor.snapshot = liveSnapshot(at: now, inventory: inventory, eligible: inventory.eligible)
        let dwell = fixation.decision(at: now)
        fixationProgress.doubleValue = (dwell.state == .collecting || dwell.state == .stable) ? dwell.progress * 100 : 0
        if running, overlay == nil, model != nil, markerButton.state == .on,
           let id = calibratedDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id }),
           screen.cgFrame == calibratedFrame {
            screenMarker.show(snapshot: monitor.snapshot, on: screen)
        } else { screenMarker.hide() }
        guard liveTimer != nil, running, overlay == nil, !inventoryBusy, now - lastInventoryRequest >= 0.35 else { return }
        lastInventoryRequest = now
        inventoryBusy = true
        let epoch = inventoryEpoch
        let markerID = screenMarker.windowID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readInventory(ignoring: markerID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inventoryBusy = false
                guard epoch == self.inventoryEpoch, self.running, self.overlay == nil, !self.switcherOpen else { return }
                self.inventory = result
            }
        }
    }

    private func liveSnapshot(at now: Double, inventory: Inventory, eligible: Set<CGWindowID>) -> GazeMonitorView.Snapshot {
        var snapshot = GazeMonitorView.Snapshot()
        snapshot.displayBounds = calibratedFrame
        if snapshot.displayBounds == nil, displays.indices.contains(screenChoice.indexOfSelectedItem) {
            snapshot.displayBounds = displays[screenChoice.indexOfSelectedItem].cgFrame
        }
        snapshot.windows = inventory.windows
        snapshot.windowLabels = inventory.labels
        snapshot.errorRadius = validation?.errorRadius
        func message(_ headline: String, _ detail: String) -> GazeMonitorView.Snapshot {
            snapshot.headline = headline; snapshot.detail = detail
            return snapshot
        }
        guard running else { return message("Camera off", "1. Start camera. 2. Calibrate + test. 3. Look at a visible window, then hold ⌥Tab.") }
        guard overlay == nil else { return message("Calibration in progress", "Look at the calibration dots. The live monitor resumes after the independent test.") }
        guard model != nil else { return message("Eyes: \(lastCameraMessage)", "Choose Calibrate + test to map detected pupils to the selected display.") }
        guard let id = calibratedDisplay, let frame = calibratedFrame,
              NSScreen.screens.contains(where: { $0.displayID == id && $0.cgFrame == frame }) else {
            return message("Display changed", "Start again and recalibrate on the display you are looking at.")
        }
        let age = now - lastSample
        guard age >= 0, age <= 0.25 else { return message("Waiting for a fresh estimate", "The last camera sample is too old. \(lastCameraMessage).") }
        snapshot.estimate = latestEstimate
        guard hasFeatures else { return message("Eyes unavailable", "\(lastCameraMessage). No point is shown until usable pupils return.") }
        guard latestEstimate != nil else { return message("Outside calibrated posture", "Pupils detected, but this eye/head position is outside the learned range. Return to your calibration posture or recalibrate.") }
        let decision = fixation.decision(at: now)
        snapshot.stablePoint = decision.stablePoint
        guard let validation, validation.passed else { return message("Test did not pass · hints off", "The dot is diagnostic only. Recalibrate or test again before using window suggestions.") }
        switch decision.state {
        case .missing: return message("No gaze estimate", "Waiting for usable pupil samples.")
        case .stale: return message("Estimate expired", "Waiting for recent camera frames.")
        case .collecting: return message(String(format: "Hold your gaze · %.0f%%", decision.progress * 100), "Keep looking at the same place for at least 0.3 seconds and five usable frames.")
        case .unstable: return message("Gaze is moving", "The orange point is the estimate. Hold still until the mint cross appears.")
        case .stable: break
        }
        guard let point = decision.stablePoint else { return snapshot }
        guard inventory.collectedAt > 0, now - inventory.collectedAt <= 1 else {
            return message("Refreshing visible windows", "The gaze is steady. Waiting for fresh desktop geometry before naming a candidate.")
        }
        let candidate = Gaze.candidateDecision(point: point, radius: validation.errorRadius, screen: frame,
                                               windows: inventory.windows, eligible: eligible)
        snapshot.candidateID = candidate.candidateID
        switch candidate.reason {
        case .accepted:
            return message("Candidate: \(candidate.candidateID.flatMap { inventory.labels[$0] } ?? "window")", "Hold ⌥Tab now to mark this window. Gaze suggests; keys and clicks still choose.")
        case .nearWindowEdge: return message("Uncertain between windows", "The dashed error margin crosses a window edge or another window. Look farther inside a large visible window.")
        case .ineligibleWindow: return message("Window cannot be suggested", "Controls, menus or an unlisted window cover the error margin. Close this panel to try another window; reopen from the Zonas menu.")
        case .desktop: return message("Looking at the desktop", "No switcher window covers the full estimated error margin.")
        case .outsideDisplay: return message("Too close to the display edge", "The estimated error margin extends beyond the calibrated display.")
        case .invalidInput: return message("Estimate unavailable", "Recalibrate to restore valid display and error bounds.")
        }
    }

    @objc private func start() {
        guard devices.indices.contains(cameraChoice.indexOfSelectedItem) else { return }
        clearCalibration()
        sampleInterval = 0
        lastSample = ProcessInfo.processInfo.systemUptime
        camera.start(deviceID: devices[cameraChoice.indexOfSelectedItem].uniqueID)
        watchdog?.invalidate()
        let watch = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.running, ProcessInfo.processInfo.systemUptime - self.lastSample > 4 else { return }
            self.stop()
            self.status.stringValue = "No camera frames for 4 seconds. Start again and recalibrate."
        }
        RunLoop.main.add(watch, forMode: .common); watchdog = watch
    }

    @objc private func calibrate() { begin(testOnly: false) }
    @objc private func retest() { begin(testOnly: true) }
    @objc private func choiceChanged() { clearCalibration(); updateButtons() }

    private func begin(testOnly: Bool) {
        guard running, overlay == nil, displays.indices.contains(screenChoice.indexOfSelectedItem) else { return }
        let screen = displays[screenChoice.indexOfSelectedItem]
        if testOnly && (model == nil || calibratedDisplay != screen.displayID || calibratedFrame != screen.cgFrame) { return }
        if !testOnly { clearCalibration() }
        // A previous success cannot keep supplying hints during or after a
        // failed retest. Only the next independently measured result can.
        validation = nil; fixation.reset()
        testingOnly = testOnly
        groups = []; targetIndex = 0
        let train = Self.trainingTargets
        targets = testOnly ? Self.testTargets : train + Self.testTargets
        calibratedDisplay = screen.displayID; calibratedFrame = screen.cgFrame
        let overlay = GazeCalibrationWindow(contentRect: screen.frame, styleMask: [.borderless],
                                             backing: .buffered, defer: false)
        overlay.level = .floating
        overlay.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        overlay.contentView = GazeTargetView()
        overlay.onCancel = { [weak self] in
            guard let self else { return }
            Log.write("gaze POC: calibration cancelled by Esc at target \(self.targetIndex + 1)/\(self.targets.count), \(self.collector.samples.count) usable samples")
            self.clearCalibration()
            self.report.stringValue = "Calibration cancelled with Esc. No hints enabled."
            self.updateButtons()
            self.open()
        }
        self.overlay = overlay
        overlay.makeKeyAndOrderFront(nil)
        targetBegan = ProcessInfo.processInfo.systemUptime
        collector = Gaze.Collector(began: targetBegan)
        Log.write("gaze POC: \(testOnly ? "independent test" : "calibration") started, \(targets.count) targets")
        drawTarget()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        updateButtons()
    }

    // Interleaved corners and centre keep a slow lighting/head drift from
    // becoming a monotonic horizontal gaze signal during training.
    static let trainingTargets = [CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.92, y: 0.92),
                                  CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.92, y: 0.08),
                                  CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.5, y: 0.08),
                                  CGPoint(x: 0.5, y: 0.92), CGPoint(x: 0.08, y: 0.5), CGPoint(x: 0.92, y: 0.5)]
    static let testTargets = [CGPoint(x: 1.0 / 6, y: 0.25), CGPoint(x: 5.0 / 6, y: 0.75),
                              CGPoint(x: 0.5, y: 0.25), CGPoint(x: 1.0 / 6, y: 0.75),
                              CGPoint(x: 5.0 / 6, y: 0.25), CGPoint(x: 0.5, y: 0.75)]

    private func receive(_ features: Gaze.Features?, message: String, at time: Double) {
        let interval = time - lastSample
        if interval > 0, interval < 2 {
            sampleInterval = sampleInterval == 0 ? interval : sampleInterval * 0.8 + interval * 0.2
        }
        lastSample = time
        lastCameraMessage = message
        hasFeatures = features != nil
        latestEstimate = features.flatMap { model?.predict($0) }
        if time - lastStatusUpdate > 0.3 {
            let rate = sampleInterval > 0 ? String(format: " · %.0f frames/s", 1 / sampleInterval) : ""
            status.stringValue = "Camera on · " + message + rate
            lastStatusUpdate = time
        }
        if overlay != nil {
            // Frames acquired while the previous dot was still visible are
            // never assigned to the next target, even if inference ran late.
            collector.add(features, at: time)
            fixation.reset()
        } else {
            fixation.add(latestEstimate, at: time)
        }
    }

    private func tick() {
        guard overlay != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if collector.timedOut(at: now) {
            let count = collector.samples.count
            let point = targetIndex + 1
            let total = targets.count
            let reason = now - lastSample > 1 ? "No recent camera frames" : lastCameraMessage
            Log.write("gaze POC: calibration stopped at target \(point)/\(total), \(count)/\(Gaze.Collector.minimumSamples) usable samples in \(Gaze.Collector.timeout) s — \(reason)")
            clearCalibration()
            report.stringValue = "Stopped at point \(point)/\(total): \(count)/\(Gaze.Collector.minimumSamples) usable pupil samples in \(Int(Gaze.Collector.timeout)) seconds.\nCamera: \(reason).\nFace the camera, improve lighting, then calibrate again. No hints enabled."
            updateButtons()
            open()
            return
        }
        guard collector.ready(at: now) else { drawTarget(); return }
        Log.write("gaze POC: target \(targetIndex + 1)/\(targets.count) collected \(collector.samples.count) usable samples")
        groups.append(Gaze.Group(target: targets[targetIndex], samples: collector.samples))
        targetIndex += 1
        if targetIndex == targets.count { finish() }
        else {
            targetBegan = ProcessInfo.processInfo.systemUptime
            collector = Gaze.Collector(began: targetBegan)
            drawTarget()
        }
    }

    private func finish() {
        closeOverlay()
        if !testingOnly {
            training = Array(groups.prefix(9))
            model = Gaze.fit(training)
        }
        guard let model, let frame = calibratedFrame else {
            clearCalibration()
            report.stringValue = "Pupil movement was insufficient to fit a gaze model. Reposition the camera and try again."
            updateButtons(); return
        }
        let test = testingOnly ? groups : Array(groups.dropFirst(9))
        validation = Gaze.validate(model, groups: test, trainingTargets: training.map(\.target))
        guard let result = validation else {
            report.stringValue = "Validation incomplete. No hints enabled."
            updateButtons(); return
        }
        let pixelError = hypot(result.errorRadius.width * frame.width, result.errorRadius.height * frame.height)
        report.stringValue = String(format: "%@\nRegions: %d/%d · valid predictions: %.0f%%\nMedian error: %.1f%% · P90: %.1f%% of normalized screen\nConservative error box: ±%.0f × %.0f pt (%.0f pt diagonal).\n%@",
                                    result.passed ? "TEST PASSED · advisory hints enabled" : "TEST FAILED · hints remain off",
                                    result.correctRegions, result.count, result.coverage * 100,
                                    result.medianError * 100, result.p90Error * 100,
                                    result.errorRadius.width * frame.width, result.errorRadius.height * frame.height,
                                    pixelError, result.passed ? "Look at a visible window, then hold ⌥Tab. A mint dot marks the estimate; keys and clicks still choose." : "Try a camera facing you near this display, better light, or larger windows.")
        Log.write("gaze POC: independent validation \(result.passed ? "passed" : "failed"), regions \(result.correctRegions)/\(result.count), median \(result.medianError), P90 \(result.p90Error)")
        updateButtons()
        window?.makeKeyAndOrderFront(nil)
    }

    private func drawTarget() {
        guard let view = overlay?.contentView as? GazeTargetView, targets.indices.contains(targetIndex) else { return }
        view.target = targets[targetIndex]
        let phase = testingOnly || targetIndex >= 9 ? "Independent test" : "Calibration"
        let index = testingOnly ? targetIndex + 1 : (targetIndex >= 9 ? targetIndex - 8 : targetIndex + 1)
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = max(0, Gaze.Collector.timeout - (now - targetBegan))
        let message = now - lastSample > 1 ? "Waiting for camera frames" : lastCameraMessage
        let progress = String(format: "Usable pupil samples: %d/%d · %.1f s left",
                              collector.samples.count, Gaze.Collector.minimumSamples, remaining)
        view.caption = "\(phase) · \(index)/\(phase == "Calibration" ? 9 : 6) · Look at the dot\n\(progress)\n\(message)\nKeep your normal posture · Esc cancels"
        // Elapsed settling time is not evidence that the camera sees pupils.
        view.ready = collector.ready(at: now)
        view.needsDisplay = true
    }

    private func closeOverlay() {
        timer?.invalidate(); timer = nil
        overlay?.orderOut(nil); overlay = nil
        fixation.reset()
    }

    private func clearCalibration() {
        closeOverlay()
        model = nil; validation = nil; training = []; groups = []
        collector = Gaze.Collector(began: 0)
        calibratedDisplay = nil; calibratedFrame = nil
        latestEstimate = nil; hasFeatures = false
        inventoryEpoch += 1; inventory = Inventory()
        screenMarker.hide()
        monitor.snapshot = GazeMonitorView.Snapshot(headline: "Calibration cleared", detail: "Start the camera and calibrate to restore a live gaze estimate.")
        fixationProgress.doubleValue = 0
        lastShortcut.stringValue = "Last ⌥Tab: not tried yet. Look at a window before pressing the shortcut."
        report.stringValue = "No calibration yet. A successful test enables an advisory mark in ⌥Tab."
    }

    private func refreshChoices() {
        refreshCameras()
        displays = NSScreen.screens
        screenChoice.removeAllItems(); screenChoice.addItems(withTitles: displays.map { "\($0.localizedName) · \(Int($0.frame.width)) × \(Int($0.frame.height))" })
        if let largest = displays.indices.max(by: { displays[$0].frame.width < displays[$1].frame.width }) {
            screenChoice.selectItem(at: largest)
        }
        updateButtons()
    }

    private func refreshCameras() {
        let previous = devices.indices.contains(cameraChoice.indexOfSelectedItem)
            ? devices[cameraChoice.indexOfSelectedItem].uniqueID : nil
        devices = GazeCamera.devices
        cameraChoice.removeAllItems(); cameraChoice.addItems(withTitles: devices.map(\.localizedName))
        if let previous, let index = devices.firstIndex(where: { $0.uniqueID == previous }) {
            cameraChoice.selectItem(at: index)
        }
    }

    private func updateButtons() {
        startButton.isEnabled = !running && !starting && !devices.isEmpty
        stopButton.isEnabled = running || starting
        cameraChoice.isEnabled = !running && !starting
        screenChoice.isEnabled = overlay == nil
        calibrateButton.isEnabled = running && overlay == nil && !displays.isEmpty
        retestButton.isEnabled = running && overlay == nil && model != nil
        markerButton.isEnabled = running && overlay == nil
        updateLiveTimer()
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 870),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Zonas · Gaze experiment"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 680, height: 870))
        window.contentView = content
        func label(_ text: String, _ rect: CGRect, bold: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.frame = rect; label.font = .systemFont(ofSize: bold ? 20 : 13, weight: bold ? .semibold : .regular)
            content.addSubview(label)
        }
        label("See what your gaze is doing.", CGRect(x: 24, y: 818, width: 632, height: 30), bold: true)
        label("Start camera → Calibrate + test → Watch the live map. Look at a window before holding ⌥Tab: the shortcut freezes one suggestion. Gaze does not automatically select or focus windows.", CGRect(x: 24, y: 756, width: 632, height: 52))
        label("Camera", CGRect(x: 24, y: 722, width: 74, height: 20))
        cameraChoice.frame = CGRect(x: 104, y: 718, width: 552, height: 28)
        label("Display", CGRect(x: 24, y: 687, width: 74, height: 20))
        screenChoice.frame = CGRect(x: 104, y: 683, width: 552, height: 28)
        screenChoice.target = self; screenChoice.action = #selector(choiceChanged)
        content.addSubview(cameraChoice); content.addSubview(screenChoice)
        let buttons = [(startButton, "Start camera", #selector(start)),
                       (calibrateButton, "Calibrate + test", #selector(calibrate)),
                       (retestButton, "Test again", #selector(retest)),
                       (stopButton, "Stop", #selector(stop))]
        var x: CGFloat = 24
        for (button, title, action) in buttons {
            button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
            let width: CGFloat = title == "Calibrate + test" ? 150 : (title == "Stop" ? 70 : 130)
            button.frame = CGRect(x: x, y: 640, width: width, height: 32); x += width + 4
            content.addSubview(button)
        }
        status.frame = CGRect(x: 24, y: 598, width: 632, height: 34)
        status.font = .systemFont(ofSize: 12); content.addSubview(status)
        report.frame = CGRect(x: 24, y: 482, width: 632, height: 112)
        report.font = .systemFont(ofSize: 12); content.addSubview(report)
        if !AXIsProcessTrusted() {
            label("For ⌥Tab, grant Accessibility to this POC through the Zonas menu.", CGRect(x: 24, y: 463, width: 632, height: 18))
        }
        monitor.frame = CGRect(x: 24, y: 135, width: 632, height: 320)
        content.addSubview(monitor)
        markerButton.frame = CGRect(x: 24, y: 100, width: 340, height: 26)
        markerButton.target = self; markerButton.action = #selector(markerChanged)
        content.addSubview(markerButton)
        label("Steady gaze", CGRect(x: 394, y: 103, width: 82, height: 20))
        fixationProgress.frame = CGRect(x: 484, y: 106, width: 172, height: 12)
        fixationProgress.isIndeterminate = false; fixationProgress.minValue = 0; fixationProgress.maxValue = 100
        content.addSubview(fixationProgress)
        lastShortcut.frame = CGRect(x: 24, y: 50, width: 632, height: 45)
        lastShortcut.font = .systemFont(ofSize: 12); content.addSubview(lastShortcut)
        label("Close this panel to see other windows; reopen it from the Zonas menu.\nStop turns the camera off. Quitting discards calibration. Frames stay in memory.", CGRect(x: 24, y: 5, width: 632, height: 40))
        self.window = window
        refreshChoices()
    }
}

private final class GazeCalibrationWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class GazeTargetView: NSView {
    var target = CGPoint(x: 0.5, y: 0.5)
    var caption = ""
    var ready = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); bounds.fill()
        let centre = CGPoint(x: target.x * bounds.width, y: target.y * bounds.height)
        (ready ? NSColor.systemMint : NSColor.white).setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - 12, y: centre.y - 12, width: 24, height: 24)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (caption as NSString).draw(in: CGRect(x: 20, y: bounds.height / 2 + 25, width: bounds.width - 40, height: 145),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white,
                                                    .paragraphStyle: paragraph])
    }
}
