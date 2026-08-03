import AppKit
import ApplicationServices

/// Detects window drags and fires the snap.
///
/// This is the heart of the matter and also the only awkward part. macOS
/// **exposes no API** that tells you "the user is moving window X". The closest
/// you can get is this: an event tap that watches the session's mouse events
/// and, on the first movement past the threshold, asks the Accessibility API
/// which window was under the point where the drag started.
///
/// The tap is read-only (`.listenOnly`): it observes events and lets them
/// through untouched. If it intercepted them, any slowness in this code would
/// feel like lag across the whole system.
final class DragMonitor {

    /// Key that reveals the zones while dragging.
    ///
    /// Shift out of habit inherited from FancyZones, and because Option is
    /// already taken by the native macOS tiling: stepping on it would make the
    /// two fight each other.
    static let modifier: CGEventFlags = .maskShift

    /// How far the mouse has to move before it counts as a drag and not a click
    /// with an unsteady hand.
    private let dragThreshold: CGFloat = 8

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var startPoint: CGPoint?
    private var draggedWindow: AXWindow?
    private var isDragging = false
    private var isOverlayVisible = false

    private let overlay = OverlayController()

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        // It isn't called twice today, but any periodic re-check added later
        // would leak the previous CFMachPort and leave two live taps receiving
        // everything. One line prevents that.
        stop()

        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = events.reduce(into: CGEventMask(0)) { $0 |= 1 << $1.rawValue }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DragMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Almost always means the Accessibility permission is missing:
            // without it the system won't let the tap be created and returns
            // nil with no further detail.
            //
            // If this shows up WITH the permission granted in Settings, the
            // suspect isn't the permission but the signature requirement, which
            // is why the fingerprint gets logged here too.
            Log.write("tap: FAILED to create — signature \(signatureFingerprint())")
            Log.write("tap: if the switch is on, compare against "
                      + "`codesign -d -r- /Applications/Zonas.app`")
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                          tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = runLoopSource
        Log.write("tap: active, listening to the mouse")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        overlay.hide()
    }

    // MARK: - Events

    /// The tap runs on the main run loop, so this is already on the UI thread
    /// and can touch the overlay without dispatching.
    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            startPoint = event.location
            draggedWindow = nil
            isDragging = false

        case .leftMouseDragged:
            handleDrag(event)

        case .leftMouseUp:
            handleDrop(event)

        // The system disables the tap if it takes too long to respond. When
        // that happens it has to be re-enabled or the app goes deaf forever.
        //
        // Both are logged, told apart: `byUserInput` is benign and happens all
        // the time, but `byTimeout` means the callback took too long and is the
        // only evidence that would tell whether this should someday move off
        // the main thread. It used to re-enable silently, leaving no trace.
        case .tapDisabledByTimeout:
            Log.write("tap: disabled by TIMEOUT — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .tapDisabledByUserInput:
            Log.write("tap: disabled by user input — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        default:
            break
        }
    }

    private func handleDrag(_ event: CGEvent) {
        guard let start = startPoint else { return }
        let current = event.location

        if !isDragging {
            let distance = hypot(current.x - start.x, current.y - start.y)
            guard distance >= dragThreshold else { return }
            isDragging = true
            // The window is looked up under the starting point, not the current
            // one: by the time the threshold is crossed the cursor may already
            // be over a different one.
            draggedWindow = AXWindow.at(cgPoint: start)
            Log.write(draggedWindow == nil
                ? "drag: no window identified at \(describe(start))"
                : "drag: window identified at \(describe(start))")
        }

        // The overlay shows even when no window was identified. Keeping the two
        // apart is deliberate: if the preview appears but nothing snaps, the
        // problem is in the identification; if nothing appears at all, the
        // problem is earlier, in the tap or in the modifier.
        if event.flags.contains(Self.modifier) {
            guard let screen = NSScreen.containing(cgPoint: current) else { return }
            if !isOverlayVisible { Log.write("overlay: showing zones") }
            overlay.show(cursor: current, on: screen)
            isOverlayVisible = true
        } else if isOverlayVisible {
            overlay.hide()
            isOverlayVisible = false
        }
    }

    private func describe(_ p: CGPoint) -> String {
        "(\(Int(p.x)), \(Int(p.y)))"
    }

    private func handleDrop(_ event: CGEvent) {
        defer {
            overlay.hide()
            isOverlayVisible = false
            isDragging = false
            startPoint = nil
            draggedWindow = nil
        }

        guard isOverlayVisible else { return }

        guard let window = draggedWindow else {
            Log.write("drop: there was a zone but no window to move")
            return
        }
        guard let screen = NSScreen.containing(cgPoint: event.location),
              let target = ZoneStore.shared.zone(under: event.location,
                                                 in: screen.cgVisibleFrame)
        else {
            Log.write("drop: the cursor didn't land inside any zone")
            return
        }

        Log.write("drop: snapping into \"\(target.zone.name)\" \(target.rect)")
        window.setFrame(target.rect)
    }
}
