import AppKit
import Carbon

/// The keys that move the front window, registered with the system.
///
/// **It is `RegisterEventHotKey`, and that is a decision about what this app
/// listens to.** The other two ways to hear a key from a menu bar app are a
/// `CGEventTap` on `keyDown` and `NSEvent.addGlobalMonitorForEvents`, and both
/// hand the process every keystroke on the machine, to be filtered for the six
/// it wants. `DragMonitor` already refuses a permanent tap on the keyboard for
/// exactly that reason — it is the uncomfortable question an open-source window
/// manager should not invite — and a second file quietly opening one would
/// undo the promise the first one makes. A Carbon hot key is the honest
/// mechanism: the app names six combinations, macOS tells it when one is
/// pressed, and it never sees anything else you type. It also *takes* the key,
/// so ⌃⌥→ moves the window instead of also moving the cursor a word in whatever
/// was in front. It needs no permission of its own; moving the window needs the
/// one Zonas already has.
///
/// Carbon is thirty years old and the call is not deprecated. Rectangle,
/// Magnet, Alfred and Raycast all register their keys through it today.
///
/// **A hot key does not fire for an event the same process posts.** Measured
/// while deciding how this could be verified: `CGEvent.post` at the HID tap,
/// at the session tap, and with the modifier keys pressed for real around the
/// arrow — none of the three reached the handler, and the same key sent by
/// System Events from another process did. So the shortcuts are exercised from
/// the shell with `osascript … key code 124 using {control down, option down}`,
/// never from inside the app.
final class ShortcutController {

    /// What each key does. The order is the order they are registered in and
    /// the identity the handler gets back.
    enum Action: Int, CaseIterable {
        case left = 1, right, up, down, maximise, place

        var direction: Direction? {
            switch self {
            case .left: return .left
            case .right: return .right
            case .up: return .up
            case .down: return .down
            case .maximise, .place: return nil
            }
        }

        /// The key pressed with the chord. Arrows are where every window
        /// manager puts them; ↩ is what all three of Rectangle, Magnet and
        /// Spectacle use for the whole screen, so it is in people's fingers
        /// already; and Z is the one letter none of them has taken — it is for
        /// *zone*, and it snaps the window into the zone it is already over.
        var keyCode: Int {
            switch self {
            case .left: return kVK_LeftArrow
            case .right: return kVK_RightArrow
            case .up: return kVK_UpArrow
            case .down: return kVK_DownArrow
            case .maximise: return kVK_Return
            case .place: return kVK_ANSI_Z
            }
        }

        var symbol: String {
            switch self {
            case .maximise: return "↩"
            case .place: return "Z"
            default: return direction!.symbol
            }
        }
    }

    private var chord: Chord?
    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []

    /// Registers the keys for a chord, or lets go of them for `nil`.
    ///
    /// Called with whatever the file says, every time the file is read, and it
    /// does nothing when nothing changed — a reload that only moved a zone must
    /// not unregister and re-register six keys for the same chord.
    func apply(_ chord: Chord?) {
        guard chord != self.chord || handler == nil else { return }
        unregister()
        self.chord = chord

        guard let chord else {
            Log.write("keys: off — the file says shortcuts: false")
            return
        }

        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let context, let event else { return noErr }
                    var id = EventHotKeyID()
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
                    let controller = Unmanaged<ShortcutController>.fromOpaque(context)
                        .takeUnretainedValue()
                    if let action = Action(rawValue: Int(id.id)) { controller.perform(action) }
                    return noErr
                },
                1, &spec,
                Unmanaged.passUnretained(self).toOpaque(),
                &handler)
        }

        var taken: [String] = []
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(action.keyCode),
                ShortcutController.carbonFlags(of: chord),
                EventHotKeyID(signature: ShortcutController.signature, id: UInt32(action.rawValue)),
                GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered.append(reference)
            } else {
                // Rule 9. Another window manager holding ⌃⌥→ is the likely
                // cause, and from outside the app it looks exactly like the
                // feature not existing.
                taken.append("\(chord.symbol)\(action.symbol)"
                             + (status == eventHotKeyExistsErr
                                ? " is held by another application" : " failed with \(status)"))
            }
        }

        Log.write("keys: \(chord.symbol) with ← → ↑ ↓ moves the front window, "
                  + "\(chord.symbol)↩ fills the screen, \(chord.symbol)Z places it in its zone")
        taken.forEach { Log.write("keys: \($0) — that key will do nothing") }
    }

    private func unregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
    }

    /// Moves the front window, and says what it did or why it did not.
    ///
    /// Every answer is computed from where the window is *now* and nothing
    /// else: the layout the store holds, the screen under the window's middle,
    /// and its frame. Nothing is remembered between two presses, which is the
    /// property that was asked for.
    private func perform(_ action: Action) {
        let key = "\(chord?.symbol ?? "")\(action.symbol)"
        let layout = LayoutStore.shared.layout

        let window: AXWindow
        switch AXWindow.focused() {
        case .nothing(let why):
            Log.write("keys: \(key) — nothing to move: \(why)")
            return
        case .window(let found) where layout.ignores(found.bundleID):
            Log.write("keys: \(key) — leaving \(found.name) alone, "
                      + "\(found.bundleID ?? "it") is in the file's ignore list")
            return
        case .window(let found):
            window = found
        }

        guard let frame = window.frame else {
            Log.write("keys: \(key) — \(window.name) would not say where it is")
            return
        }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.containing(cgPoint: middle) else {
            Log.write("keys: \(key) — \(window.name) is on no screen")
            return
        }
        let area = screen.cgVisibleFrame
        // Where its middle is, for the log. "In" and not "from": ↩ leaves the
        // middle in the same zone it started in, and "from Centro into Centro"
        // read as a bug when it was a maximised window being put back.
        let inside = layout.zoneIndex(holding: frame, in: area)
            .map { "in \"\(layout.zones[$0].name)\"" } ?? "outside every zone"

        let target: Zone?
        switch action {
        case .maximise:
            target = Layout.maximised
        case .place:
            target = layout.zoneIndex(holding: frame, in: area).map { layout.zones[$0] }
        default:
            target = layout.neighbour(of: frame, towards: action.direction!, in: area)
                .map { layout.zones[$0] }
        }
        guard let target else {
            Log.write("keys: \(key) — \(window.name) is \(inside), "
                      + "and nothing is \(action.symbol) of it on this screen")
            return
        }

        let rect = layout.frame(of: target, in: area)
        Log.write("keys: \(key) — \(window.name), \(inside), into \"\(target.name)\" \(rect)")
        window.setFrame(rect, inside: area)
    }

    /// `ZONA`, as the four-byte tag Carbon asks every hot key to carry.
    private static let signature: OSType = 0x5A4F_4E41

    private static func carbonFlags(of chord: Chord) -> UInt32 {
        var flags = 0
        if chord.keys.contains(.shift) { flags |= shiftKey }
        if chord.keys.contains(.control) { flags |= controlKey }
        if chord.keys.contains(.option) { flags |= optionKey }
        if chord.keys.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }
}
