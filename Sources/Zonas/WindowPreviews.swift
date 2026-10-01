import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// Pictures of other applications' windows for ⌥Tab, when Zonas is allowed to
/// take them.
///
/// **Only ever asked for from the menu.** A picture of another application's
/// window needs the Screen Recording permission: the one people associate
/// with spyware, which the editor turned down rather than ask for to draw a
/// grey rectangle, and which ⌥Tab went without in its first version. It is
/// here because a picture of the window was asked for by name, and it is
/// opt-in because the switcher needs nothing it gives: `isAllowed` only looks,
/// and the one request is `request()`, behind a menu item somebody has to
/// choose.
///
/// **And macOS keeps asking.** From macOS 15, an application that captures the
/// screen directly is asked to confirm it again every so often, with a dialog
/// saying it wants to "bypass the system private window picker and directly
/// access your screen". Seen on this machine the first time a screenshot was
/// taken from the shell of the Claude app — the same dialog, with Claude's
/// name in it. Anybody turning previews on should expect it with Zonas'.
final class WindowPreviews {

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - What was asked for, which is not the same as what is allowed

    /// `UserDefaults` and not the layout file: Rule 3. Whether this machine
    /// draws pictures of windows is this machine's business — it is bounded by
    /// a permission that belongs to this machine and to no other, and a layout
    /// committed to a dotfiles repo has no business carrying it to a desk where
    /// that permission was never granted.
    ///
    /// Both exist because the permission was the only switch there was. Once it
    /// was granted the menu said "Window Previews Are On" and did nothing, so
    /// the only way back was System Settings — for a feature Zonas had asked for
    /// by name. These are the way back, and the second one is the one asked for
    /// at the desk: the picture in the strip and the picture out on the window
    /// are worth wanting separately.
    static let onKey = "windowPreviews"
    static let inRingKey = "windowPreviewInRing"

    /// **`object(forKey:)` and not `bool(forKey:)`**, which answers `false` for
    /// a key nobody has written and would turn previews off for everybody who
    /// has never opened this menu — the one place where the absence of an
    /// opinion and an opinion of "no" are not the same thing.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: onKey) as? Bool ?? true
    }

    static func setOn(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: onKey)
    }

    /// Independent of the carousel: show a live picture at the window position.
    static func isInRing(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: inRingKey) as? Bool ?? true
    }

    static func setInRing(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: inRingKey)
    }

    /// Puts up macOS's own prompt the first time, and opens the Screen
    /// Recording pane of System Settings, which is where the switch is — and
    /// where it is every time after the first, when there is no prompt.
    static func request() {
        _ = CGRequestScreenCaptureAccess()
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }

    /// The last picture of each window, shown straight away the next time it
    /// is chosen while a fresh one is taken — a picture a few seconds old is
    /// a better stand-in than none. Held in memory for as long as the window
    /// is open, and never written anywhere.
    private var pictures: [CGWindowID: NSImage] = [:]
    private var inFlight: Set<CGWindowID> = []

    /// The last list of what there is to capture, and the one being fetched.
    ///
    /// ScreenCaptureKit needs its own description of a window before it will
    /// capture it, and listing every window on the machine took 52 to 62 ms
    /// here — 324 of them — against about 40 for the capture itself. So a
    /// window that was already open the last time the list was fetched is
    /// captured from that list straight away, and only one opened since waits
    /// for the fresh one. That puts the first picture ahead of the panel's
    /// 130 ms rather than after it.
    private var listed: SCShareableContent?
    private var listing: Task<SCShareableContent?, Never>?

    /// A new ⌥Tab. The pictures of windows that are no longer open are let go.
    func begin(windows: Set<CGWindowID>) {
        pictures = pictures.filter { windows.contains($0.key) }
        refreshList()
    }

    /// Fetches the list of what there is to capture, without capturing
    /// anything — which is why it can be done at launch, when nobody has
    /// asked to see a window yet.
    func refreshList() {
        let fetch = Task {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        listing = fetch
        Task {
            guard let fresh = await fetch.value else { return }
            await MainActor.run { self.listed = fresh }
        }
    }

    func end() {
        stopStream()
        listing = nil
    }

    func picture(of window: CGWindowID) -> NSImage? {
        pictures[window]
    }

    /// Takes a picture of one window at the size it will be shown, and hands
    /// it back on the main thread. One at a time per window.
    ///
    /// `size` is the window's size now, from the WindowServer, when it is on
    /// screen: the list the capture comes from can be a press old, and a
    /// window resized since would otherwise be pictured in its old shape.
    func capture(_ window: CGWindowID, size: CGSize?, fitting box: CGSize, scale: CGFloat,
                 then deliver: @escaping (NSImage) -> Void) {
        guard box.width > 0, inFlight.insert(window).inserted else { return }
        let known = listed?.windows.first { $0.windowID == window }
        let listing = self.listing
        Task {
            var target = known
            if target == nil, let listing {
                target = await listing.value?.windows.first { $0.windowID == window }
            }
            let picture: NSImage?
            if let target {
                picture = await WindowPreviews.take(target, size: size ?? target.frame.size,
                                                    fitting: box, scale: scale)
            } else {
                picture = nil
            }
            await MainActor.run {
                self.inFlight.remove(window)
                guard let picture else { return }
                self.pictures[window] = picture
                deliver(picture)
            }
        }
    }

    private var livePictures: [CGWindowID: NSImage] = [:]
    private var liveStream: SCStream?
    private var liveOutput: LivePreviewOutput?
    private var liveWindow: CGWindowID?
    private var streamGeneration = UUID()

    func livePicture(of window: CGWindowID) -> NSImage? {
        livePictures[window]
    }

    func stopStream() {
        streamGeneration = UUID()
        liveWindow = nil
        let old = liveStream
        liveStream = nil
        liveOutput = nil
        livePictures.removeAll()
        if let old { Task { try? await old.stopCapture() } }
    }

    /// Only the selected window streams, and only while the switcher is open.
    func stream(_ window: CGWindowID, size: CGSize,
                then update: @escaping () -> Void) {
        guard liveWindow != window else { return }
        stopStream()
        liveWindow = window
        let generation = streamGeneration
        let known = listed?.windows.first { $0.windowID == window }
        let pending = listing
        Task { @MainActor in
            let target: SCWindow?
            if let known { target = known }
            else { target = await pending?.value?.windows.first { $0.windowID == window } }
            guard let target, self.streamGeneration == generation else { return }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(size.width * scale))
            config.height = max(1, Int(size.height * scale))
            // Independent window streams otherwise only scale down. A 1x
            // window in a 2x buffer occupied its top-left quarter, which the
            // preview then drew as if the whole buffer contained the window.
            config.scalesToFit = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let output = LivePreviewOutput { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.streamGeneration == generation else { return }
                    self.livePictures[window] = NSImage(cgImage: image, size: size)
                    update()
                }
            }
            let stream = SCStream(filter: filter,
                                  configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(output, type: .screen,
                                           sampleHandlerQueue: DispatchQueue(label: "uy.com.fcstudio.zonas.preview"))
                self.liveStream = stream
                self.liveOutput = output
                try await stream.startCapture()
                if self.streamGeneration != generation { try? await stream.stopCapture() }
            } catch {
                if self.streamGeneration == generation { self.stopStream() }
                Log.write("windows: live preview failed: \(error.localizedDescription)")
            }
        }
    }

    private static func take(_ window: SCWindow, size windowSize: CGSize,
                             fitting box: CGSize, scale: CGFloat) async -> NSImage? {
        let size = WindowSwitcher.fit(windowSize, into: box)
        guard size.width > 0, size.height > 0 else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                      configuration: configuration) else {
            return nil
        }
        return NSImage(cgImage: image, size: size)
    }
}

/// Convert frames away from the main thread; AppKit drawing stays on it.
private final class LivePreviewOutput: NSObject, SCStreamOutput {
    private let context = CIContext()
    private let deliver: (CGImage) -> Void

    init(deliver: @escaping (CGImage) -> Void) { self.deliver = deliver }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        if let image = context.createCGImage(frame, from: frame.extent) { deliver(image) }
    }
}
