import AppKit
import ScreenCaptureKit

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
