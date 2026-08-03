import AppKit
final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
func check() {
    let w = EditorWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .floating
    w.ignoresMouseEvents = false
    w.collectionBehavior = [.fullScreenAuxiliary, .stationary]
    NSApp.activate()                    // macOS 14+
    NSApp.activate(ignoringOtherApps: true)
    _ = NSCursor.resizeLeftRight
    _ = NSCursor.resizeUpDown
    _ = NSVisualEffectView.Material.hudWindow
    _ = NSApplication.didChangeScreenParametersNotification
    _ = NSScreen.main?.localizedName
    _ = NSPasteboard.general
    _ = w.canBecomeKey
}
print("api surface compiles")
