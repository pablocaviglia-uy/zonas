import AppKit
import Carbon

/// ⌥Tab, wired to the system: the keys, reading the windows, the list on
/// screen, and bringing the chosen window forward.
///
/// Which windows, in what order, and where a press lands are decided in
/// `WindowSwitcher`, where a test can reach them. Nothing here decides.
///
/// **The keys are hot keys, for the reason `ShortcutController` gives:** Zonas
/// names ⌥Tab and ⌥⇧Tab to macOS and hears nothing else anybody types. While
/// the list is up it names one more, ⌥Esc, and lets go of it as soon as the
/// list is gone. That is also why the Tab and Escape never reach the
/// application in front.
///
/// **Letting go of ⌥ is read off the modifier state, not heard.** A hot key
/// says when a combination goes down and never when a key comes up, and the
/// commit is ⌥ coming up. The drag's tap does hear modifiers, and was the
/// other candidate, and it lost on two counts: the editor suspends it, which
/// would leave a list on screen that no release could ever close, and its
/// events and the hot key's arrive by two different routes with nothing to say
/// which came first — so a quick tap could be over before the press that
/// started it had been delivered. Asking the system whether ⌥ is down, when
/// the press arrives and 120 times a second while the list is up, has
/// neither problem, reads nothing but the four modifiers, and stops the moment
/// the list closes.
final class WindowSwitcherController {

    /// What each key does. The raw value is the identity the handler gets back.
    private enum Key: UInt32 {
        case next = 1, previous, cancel, close

        var symbol: String {
            switch self {
            case .next: return "⌥Tab"
            case .previous: return "⌥⇧Tab"
            case .cancel: return "⌥Esc"
            case .close: return "⌥Q"
            }
        }
    }

    /// What the file said last, or `nil` before it has said anything — so the
    /// first answer is always acted on and logged, and every later one only
    /// when it changes.
    private var applied: Bool?
    private var handler: EventHandlerRef?

    /// ⌥Tab and ⌥⇧Tab, held for as long as the file leaves the switcher on.
    private var registered: [EventHotKeyRef] = []

    /// ⌥Esc and ⌥Q, held only while the strip is up. Held all the time, they
    /// would take both away from every application to do nothing with them —
    /// ⌥Q is "œ" on a US keyboard.
    private var whileOpen: [EventHotKeyRef] = []

    private var session: Session?
    private var opening: (token: UUID, keys: SwitcherOpening)?
    private var poll: Timer?
    private var reveal: DispatchWorkItem?
    private let panel = WindowSwitcherPanel()
    private let previews = WindowPreviews()
    private let highlight = WindowHighlight()
    private var previewHandoff = PreviewHandoff<NSImage>()
    private var previewDeadline: DispatchWorkItem?
    private var exitingPreview: (window: CGWindowID, token: UUID)?
    private var activationToken = UUID()
    private let focusChecks = SwitcherWindowCache<UUID, Bool>()

    /// How many sessions there have been, so a picture that arrives after
    /// its session has ended cannot be shown in the next one — where the same
    /// position in the strip is, as often as not, a different window.
    private var sessions = 0

    /// One ⌥Tab, from the press that opens it to the release that ends it.
    ///
    /// The list is read once, when it opens, and never again until the next
    /// one. A window that opens or closes in the middle is not on it or stays
    /// on it; the alternative is rows that move under the choice while
    /// somebody is making it.
    private struct Session {
        var entries: [WindowSwitcher.Entry<AXWindow>]
        var cycle: WindowSwitcher.Cycle
        /// Every press of Tab, the first included, so the commit can say how
        /// it got where it did. "The wrong window came up" is a report about
        /// either the list or the presses, and the log has to tell them apart.
        var presses = 1
        var previewDirection = 1
        var peakSelectionMicroseconds: UInt64 = 0
        /// The press that opened it, which every time in the log counts from.
        let began: DispatchTime
        /// Which session this is — see `sessions`.
        let number: Int
        /// Whether this one shows pictures of the windows, which is whether
        /// Screen Recording was granted when it opened **and** the menu has not
        /// been used to turn them off.
        var showsPreviews = false
        /// Whether the chosen window's picture also goes inside the ring.
        var showsGhost = false
        /// Whether the strip is on screen yet. Until it is, nothing else is
        /// drawn either: a tap shows nothing at all.
        var isRevealed = false
        /// Where the strip is, kept so that closing a window redraws it in the
        /// same place rather than following whichever window is now first.
        var screen: NSScreen?
    }

    /// A short grace period still lets a very quick tap switch without a
    /// panel. The old 130 ms floor dominated normal openings even when the
    /// inventory and preview were ready much earlier. AX no longer blocks
    /// input, so presentation now aims for 75 ms from the original press.
    private static let revealDelay: TimeInterval = 0.075

    /// How long after the switcher is turned on to read every window once,
    /// out of sight — see `warmUp`.
    private static let warmUpDelay: TimeInterval = 0.25

    init() {
        panel.onPick = { [weak self] index in self?.pick(index) }
        panel.onPoint = { [weak self] index in self?.point(at: index) }
    }

    // MARK: - The file

    /// Takes the keys, or lets go of them.
    ///
    /// Called with whatever the file says every time the file is read, and it
    /// does nothing when nothing changed.
    func apply(_ on: Bool) {
        guard on != applied else { return }
        applied = on
        end()
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []

        guard on else {
            Log.write("windows: off — the file says windowSwitcher: false")
            return
        }
        // Rule 9. Without the join there is no order, and the key would do
        // nothing whatsoever — which from outside is indistinguishable from the
        // feature not existing.
        guard AXWindow.canNumberWindows else {
            Log.write("windows: this macOS does not say which window is which — ⌥Tab is left alone")
            return
        }

        installHandler()
        for (key, modifiers) in [(Key.next, optionKey), (.previous, optionKey | shiftKey)] {
            if let reference = register(key, keyCode: kVK_Tab, modifiers: modifiers) {
                registered.append(reference)
            }
        }
        Log.write("windows: ⌥Tab goes through every window, ⌥⇧Tab the other way — "
                  + (WindowPreviews.isAllowed ? "with previews"
                                              : "previews are off until Screen Recording is allowed, from the menu"))

        DispatchQueue.main.asyncAfter(deadline: .now() + WindowSwitcherController.warmUpDelay) {
            [weak self] in self?.warmUp()
        }
    }

    /// One read of every window, and one list drawn where nobody can see it,
    /// shortly after launch.
    ///
    /// The first ⌥Tab after installing took about 410 ms to show its list,
    /// against about 210 for the ones after it, and the difference was all
    /// first times: the first conversation with each application — 156 ms
    /// apiece for Claude and Sublime Text — and the first time the panel, its
    /// rows and the applications' icons were made. None of that needs anybody
    /// to have pressed anything, and at launch nobody is waiting on it.
    ///
    /// The applications are read off the main thread, so a slow one costs the
    /// launch nothing. The list is drawn on it, because it is AppKit.
    private func warmUp() {
        guard applied == true, session == nil, opening == nil else { return }
        let started = DispatchTime.now()
        let applications = Self.applicationSnapshot()
        DispatchQueue.global(qos: .utility).async {
            let census = Self.census(applications: applications)
            // Waiting as long as it takes: nobody is, and every answer that
            // comes back is one `describe` can fall back on later.
            let windows = WindowSwitcherController.describe(census, patience: nil).windows
            DispatchQueue.main.async { [weak self] in
                guard let self, self.applied == true, self.session == nil, self.opening == nil else { return }
                let entries = WindowSwitcher.entries(listed: census.listed, windows: windows,
                                                     own: getpid()).entries
                let screen = WindowSwitcherController.screen(for: entries)
                // Prepared with room for a picture when there will be one, so
                // the panel's first reveal is the size it will usually be. No
                // picture is taken here — nothing is captured that nobody asked
                // to see — but the list of what could be is fetched, so the
                // first press does not wait for it.
                let previewing = WindowPreviews.isAllowed
                if previewing { self.previews.refreshList() }
                self.panel.prepare(WindowSwitcherController.rows(entries, around: screen), selected: 0,
                                   on: screen, showsPreview: previewing)
                Log.write("windows: ready — \(entries.count) windows read and drawn out of sight"
                          + " in \(WindowSwitcherController.milliseconds(since: started)) ms")
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                // The arrow keys arrive here too. See the same check in
                // `ShortcutController`.
                guard id.signature == WindowSwitcherController.signature,
                      let key = Key(rawValue: id.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<WindowSwitcherController>.fromOpaque(context)
                    .takeUnretainedValue().pressed(key)
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
    }

    private func register(_ key: Key, keyCode: Int, modifiers: Int) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: WindowSwitcherController.signature, id: key.rawValue),
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            // Rule 9, the same as the arrows: another switcher holding ⌥Tab is
            // the likely cause, and the symptom is a key that does nothing.
            Log.write("windows: \(key.symbol) "
                      + (status == eventHotKeyExistsErr ? "is held by another application"
                                                        : "failed with \(status)")
                      + " — that key will do nothing")
            return nil
        }
        return reference
    }

    // MARK: - A session

    private func pressed(_ key: Key) {
        switch key {
        case .next, .previous:
            let delta = key == .next ? 1 : -1
            if var pending = opening {
                pending.keys.press(backwards: key == .previous)
                opening = pending
                return
            }
            guard var current = session else {
                begin(backwards: key == .previous)
                return
            }
            let began = DispatchTime.now()
            current.cycle.step(delta)
            current.presses += 1
            current.previewDirection = delta
            session = current
            panel.select(current.cycle.index)
            showPreview(of: current.cycle.index)
            ringChoice()
            recordSelectionCost(since: began)

        case .cancel:
            guard session != nil || opening != nil else { return }
            Log.write("windows: cancelled with Esc — nothing moved")
            end()

        case .close:
            guard let current = session else {
                if opening != nil { Log.write("windows: ⌥Q while the inventory is loading — nothing closed") }
                return
            }
            // Nothing is closed that nobody has seen: during the wait before
            // the strip appears, the choice is one the person pressing has not
            // looked at yet.
            guard current.isRevealed else {
                Log.write("windows: ⌥Q before the strip was up — nothing closed")
                return
            }
            closeChosen()
        }
    }

    /// ⌥Q: closes the chosen window and keeps the strip open, so several can
    /// go before ⌥ comes up.
    ///
    /// The strip changes only once the window has actually gone. Pressing the
    /// close button is a request — Rule 8 — and an application with unsaved
    /// work answers it with a question instead, leaving the window where it
    /// was; taking it off the strip regardless would hide a window that is
    /// still open and now waiting for somebody.
    private func closeChosen() {
        guard let current = session else { return }
        let entry = current.entries[current.cycle.index]
        let window = entry.window.handle
        let name = window.name
        guard window.close() else {
            Log.write("windows: ⌥Q — \(name) has no close button to press")
            return
        }
        watchClosing(entry, name: name, session: current.number, since: DispatchTime.now())
    }

    /// Asks every quarter of a second whether the window has gone, for up to
    /// two seconds, and takes it off the strip the moment it has.
    ///
    /// Once was not enough. TextEdit took a document with text in it down
    /// more than 250 ms after its close button was pressed — after a single
    /// look had already reported it still open and waiting on a question,
    /// which left a window that no longer existed on the strip. Two seconds
    /// is long past any application taking a window down; a window still
    /// there by then is waiting for somebody to answer it.
    private func watchClosing(_ entry: WindowSwitcher.Entry<AXWindow>, name: String,
                              session number: Int, since: DispatchTime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowSwitcherController.closeSettles) { [weak self] in
            guard let self, self.session?.number == number else { return }
            let waited = WindowSwitcherController.milliseconds(since: since)
            if !WindowSwitcherController.isOpen(entry) {
                Log.write("windows: ⌥Q — closed \(name), \(waited) ms after the press")
                self.drop(entry)
            } else if waited < 2000 {
                self.watchClosing(entry, name: name, session: number, since: since)
            } else {
                Log.write("windows: ⌥Q — \(name) is still open after 2 s: it is probably asking about unsaved changes")
            }
        }
    }

    /// How often a closing window is asked whether it has gone.
    private static let closeSettles: TimeInterval = 0.25

    /// Takes a closed window off the strip and redraws it where it was, with
    /// the choice where `Cycle.removing` puts it.
    private func drop(_ entry: WindowSwitcher.Entry<AXWindow>) {
        guard var current = session else { return }
        let position = current.entries.firstIndex {
            if let id = entry.window.id, let other = $0.window.id { return id == other }
            return CFEqual($0.window.handle.element, entry.window.handle.element)
        }
        guard let position else { return }
        guard let cycle = current.cycle.removing(position) else {
            Log.write("windows: ⌥Q closed the last window on the strip")
            end()
            return
        }
        current.entries.remove(at: position)
        current.cycle = cycle
        session = current

        panel.prepare(WindowSwitcherController.rows(current.entries, around: current.screen),
                      selected: cycle.index, on: current.screen, showsPreview: current.showsPreviews)
        panel.reveal()
        showPreview(of: cycle.index)
        ringChoice()
    }

    /// Whether a window is still there: asked of the WindowServer by number,
    /// which answers for minimized windows too, and of the application only
    /// for a window with no number.
    private static func isOpen(_ entry: WindowSwitcher.Entry<AXWindow>) -> Bool {
        if let id = entry.window.id {
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            return !(info ?? []).isEmpty
        }
        return entry.window.handle.title != nil || entry.window.handle.subrole != nil
    }

    private func begin(backwards: Bool) {
        activationToken = UUID()
        if exitingPreview != nil { end() }
        var keys = SwitcherOpening()
        keys.press(backwards: backwards)
        let token = UUID()
        opening = (token, keys)
        listenWhileOpen()

        // AppKit supplies the process snapshot here; WindowServer and AX IPC
        // run elsewhere. Waiting on AX on the hot-key thread used to delay
        // the next Tab, Escape and even noticing that Option had come up.
        let applications = Self.applicationSnapshot()
        let began = keys.gestures[0].began
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let censusBegan = DispatchTime.now()
            let census = Self.census(applications: applications)
            let censusMS = Self.milliseconds(since: censusBegan)
            let describeBegan = DispatchTime.now()
            let (windows, late) = Self.describe(census, patience: Self.patience)
            let describeMS = Self.milliseconds(since: describeBegan)
            let (entries, leftOut) = WindowSwitcher.entries(listed: census.listed, windows: windows,
                                                          own: getpid())
            DispatchQueue.main.async {
                self?.opened(entries, leftOut: leftOut, late: late, token: token,
                             readMS: Self.milliseconds(since: began),
                             censusMS: censusMS, describeMS: describeMS)
            }
        }
    }

    /// A second tap can finish before the first inventory arrives. Apply each
    /// completed gesture in order, and use its chosen window as the front of
    /// the next gesture instead of losing a tap or counting it as a held Tab.
    private func opened(_ read: [WindowSwitcher.Entry<AXWindow>],
                        leftOut: [WindowSwitcher.Window<AXWindow>], late: [String], token: UUID,
                        readMS: UInt64, censusMS: UInt64, describeMS: UInt64) {
        guard var pending = opening, pending.token == token, applied == true else { return }
        if !Self.optionIsDown { pending.keys.release() }
        opening = nil
        guard !read.isEmpty else {
            Log.write("windows: ⌥Tab — there is no window to switch to"
                      + (AXIsProcessTrusted() ? "" : ": the Accessibility permission is missing"))
            end()
            return
        }
        let skipped = leftOut.isEmpty ? "" : " — left out: " + leftOut.map { window in
            let subrole = window.subrole ?? "no subrole"
            let why = AXWindow.isTheSystemsOwn(subrole: subrole) ? "the system's own" : "\(subrole), no title"
            let owner = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "An unnamed process"
            return "\(owner)'s \"\(window.title ?? "")\" (\(why))"
        }.joined(separator: ", ")
        let waited = late.isEmpty ? "" : " — not waited for: " + late.joined(separator: ", ")
        Log.write("windows: ⌥Tab — \(read.count) windows in \(readMS) ms"
                  + " (WindowServer \(censusMS) ms, AX \(describeMS) ms, off the key thread)\(waited)\(skipped)")

        var entries = read
        for gesture in pending.keys.gestures {
            guard let cycle = gesture.cycle(count: entries.count) else { continue }
            sessions += 1
            session = Session(entries: entries, cycle: cycle, presses: gesture.presses,
                              previewDirection: gesture.lastDirection,
                              began: gesture.began, number: sessions)
            if gesture.released {
                let chosen = entries.remove(at: cycle.index)
                entries.insert(chosen, at: 0)
                commit()
            } else {
                prepareSession()
            }
        }
    }

    private func listenWhileOpen() {
        if whileOpen.isEmpty {
            whileOpen = [register(.cancel, keyCode: kVK_Escape, modifiers: optionKey),
                         register(.close, keyCode: kVK_ANSI_Q, modifiers: optionKey)].compactMap { $0 }
        }
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard !Self.optionIsDown else { return }
            self?.commit()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func prepareSession() {
        guard let current = session else { return }
        listenWhileOpen()
        let entries = current.entries
        let screen = Self.screen(for: entries)
        let place = screen?.localizedName ?? "no screen"
        session?.screen = screen
        let allowed = WindowPreviews.isAllowed
        let showsPreviews = allowed && WindowPreviews.isOn()
        session?.showsPreviews = showsPreviews
        session?.showsGhost = allowed && WindowPreviews.isInRing()
        if showsPreviews || session?.showsGhost == true {
            let owners = Dictionary(entries.compactMap { entry in
                entry.window.id.map { ($0, entry.window.pid) }
            }, uniquingKeysWith: { first, _ in first })
            let identities: [CGWindowID: PreviewFrameIdentity] = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (CGWindowID, PreviewFrameIdentity)? in
                guard let id = entry.window.id, let bounds = entry.bounds else { return nil }
                return (id, PreviewFrameIdentity(owner: entry.window.pid, size: bounds.size))
            })
            previews.begin(windows: Set(entries.compactMap(\.window.id)), owners: owners, identities: identities)
        }
        let prepareBegan = DispatchTime.now()
        panel.prepare(Self.rows(entries, around: screen), selected: current.cycle.index,
                      on: screen, showsPreview: showsPreviews)
        showPreview(of: current.cycle.index)
        Log.write("windows: prepared selection in \(Self.milliseconds(since: prepareBegan)) ms")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session?.number == current.number else { return }
            guard Self.optionIsDown else {
                self.commit()
                return
            }
            self.panel.reveal()
            self.session?.isRevealed = true
            self.ringChoice()
            Log.write("windows: showing the list on \(place), "
                      + "\(Self.milliseconds(since: current.began)) ms after the press")
        }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: current.began + Self.revealDelay, execute: work)
    }

    /// The pointer moved onto a window's icon: it becomes the choice, exactly
    /// as if Tab had got there — so letting go of ⌥ takes it, and so does a
    /// click.
    private func point(at index: Int) {
        guard var current = session, current.entries.indices.contains(index) else { return }
        let began = DispatchTime.now()
        let delta = index - current.cycle.index
        current.cycle.step(delta)
        if delta != 0 { current.previewDirection = delta < 0 ? -1 : 1 }
        session = current
        panel.select(index)
        showPreview(of: index)
        ringChoice()
        recordSelectionCost(since: began)
    }

    private func recordSelectionCost(since began: DispatchTime) {
        let cost = (DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1000
        let previous = session?.peakSelectionMicroseconds ?? 0
        session?.peakSelectionMicroseconds = max(previous, cost)
    }

    /// Rings the chosen window where it is on the desktop — once the strip is
    /// on screen, and not for a window that is minimized or hidden, which is
    /// nowhere to ring.
    ///
    /// The live picture is captured separately from the carousel thumbnail.
    private func ringChoice() {
        if let exitingPreview, let picture = previews.livePicture(of: exitingPreview.window) {
            highlight.updatePicture(picture)
        }
        guard let session, session.isRevealed else { return }
        let entry = session.entries[session.cycle.index]
        let picture = pictureOfChoice(session)
        let failed = entry.window.id.map { previews.liveCaptureFailed(for: $0) } ?? false
        let previousToken = previewHandoff.pendingToken
        let previousFrame = previewHandoff.displayed
        let frame = previewHandoff.choose(window: entry.window.id, bounds: entry.bounds, picture: picture,
                                           expectsPicture: session.showsGhost && !failed)
        if let frame {
            if frame.window == previousFrame?.window, frame.bounds == previousFrame?.bounds,
               let picture = frame.picture, previousFrame?.picture != nil {
                if picture !== previousFrame?.picture { highlight.updatePicture(picture) }
            } else {
                highlight.show(frame.bounds, picture: frame.picture)
            }
        } else { highlight.hide() }

        guard let token = previewHandoff.pendingToken else {
            previewDeadline?.cancel(); previewDeadline = nil
            return
        }
        guard token != previousToken else { return }
        previewDeadline?.cancel()
        // A compositor/device failure is different from warming up. Bound the
        // wait so it cannot leave an unrelated window highlighted indefinitely.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session?.number == session.number,
                  self.previewHandoff.pendingToken == token else { return }
            if let fallback = self.previewHandoff.fail(token) {
                self.highlight.show(fallback.bounds, picture: fallback.picture)
                Log.write("windows: live preview timed out after 350 ms — showing the ring without a picture")
            }
            self.previewDeadline = nil
        }
        previewDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The picture of the chosen window, if there is one to have: `nil` for
    /// every session on a machine that has not granted Screen Recording, and
    /// for the moment before this window's first capture arrives.
    private func pictureOfChoice(_ session: Session) -> NSImage? {
        guard session.showsGhost,
              let id = session.entries[session.cycle.index].window.id else { return nil }
        return previews.livePicture(of: id)
    }

    /// An icon clicked while the strip is up.
    private func pick(_ index: Int) {
        guard var current = session else { return }
        current.cycle.step(index - current.cycle.index)
        session = current
        commit()
    }

    /// ⌥ came up: the chosen window goes to the front.
    private func commit() {
        if var pending = opening {
            pending.keys.release()
            opening = pending
            return
        }
        guard let session else { return }
        let entry = session.entries[session.cycle.index]
        let shown = previewHandoff.displayed
        let keepsPreview = session.isRevealed && session.showsGhost && entry.window.id != nil
            && shown?.window == entry.window.id && shown?.bounds == entry.bounds && shown?.picture != nil
        let token = UUID()
        if keepsPreview, let id = entry.window.id { exitingPreview = (id, token) }
        end(keepingPreview: keepsPreview)
        let activation = activationToken

        let window = entry.window.handle
        let owner = NSRunningApplication(processIdentifier: entry.window.pid)?.localizedName ?? "An unnamed process"
        let name = "\(owner)'s \"\(entry.window.title ?? "")\""
        let held = WindowSwitcherController.milliseconds(since: session.began)
        Log.write("windows: \(session.presses) \(session.presses == 1 ? "press" : "presses") in \(held) ms"
                  + " — number \(session.cycle.index + 1) of \(session.entries.count), \(name)"
                  + " (selection handling peak \(session.peakSelectionMicroseconds) µs)")
        window.bringForward()
        if keepsPreview {
            highlight.dismiss(canReveal: { [weak self] in
                self?.canReveal(window, activation: activation) ?? false
            }) { [weak self] in
                guard let self, self.exitingPreview?.token == token else { return }
                self.exitingPreview = nil
                self.previews.end()
            }
        }

        // Rule 8. A window coming back from the Dock animates for most of half
        // a second, and would read as a failure well before it had finished
        // arriving.
        let settle: TimeInterval = entry.bounds == nil ? 0.6 : 0.2
        verifyActivation(window, name: name, token: activation, settle: settle)
    }

    /// A stopped application can spend 250 ms on each AX attribute. Reading
    /// focus directly from the 60 Hz dismissal timer blocked every other key.
    /// The timer now polls a shared background answer without waiting on IPC.
    private func canReveal(_ window: AXWindow, activation: UUID) -> Bool {
        guard activationToken == activation else { return false }
        if focusChecks.snapshot(keeping: [activation])[activation] == true { return true }
        _ = focusChecks.request(activation) { window.isInFront }
        return false
    }

    private func verifyActivation(_ window: AXWindow, name: String, token: UUID,
                                  settle: TimeInterval, secondAttempt: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.activationToken == token, self.session == nil, self.opening == nil else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let ready = window.isInFront
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activationToken == token, self.session == nil, self.opening == nil else { return }
                    if ready {
                        Log.write("windows: \(name) is in front"
                                  + (secondAttempt ? ", at the second time of asking" : ""))
                    } else if secondAttempt {
                        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
                        Log.write("windows: asked for \(name) twice, and \(front) is in front")
                    } else {
                        window.askToComeForward()
                        self.verifyActivation(window, name: name, token: token, settle: settle, secondAttempt: true)
                    }
                }
            }
        }
    }

    /// The picture of the chosen window — the last one taken, straight away,
    /// and a fresh one when it arrives — and the next window's, taken ahead,
    /// since that is where the next Tab goes.
    private func showPreview(of index: Int) {
        guard let session, session.entries.indices.contains(index) else { return }
        if session.showsGhost, let id = session.entries[index].window.id,
           let bounds = session.entries[index].bounds {
            previews.stream(id, size: bounds.size) { [weak self] in
                self?.ringChoice()
            }
        } else {
            previews.stopStream()
        }
        let next = (index + session.previewDirection + session.entries.count) % session.entries.count
        if session.showsGhost, next != index,
           let id = session.entries[next].window.id, let bounds = session.entries[next].bounds {
            previews.prefetchNative(id, size: bounds.size)
        }
        guard session.showsPreviews else { return }
        let number = session.number
        for (offset, position) in [index, next].enumerated() {
            guard offset == 0 || position != index, let id = session.entries[position].window.id else { continue }
            if offset == 0 { panel.showPreview(previews.picture(of: id), forRow: position) }
            previews.capture(id, size: session.entries[position].bounds?.size,
                             fitting: panel.previewBox, scale: panel.scale) { [weak self] picture in
                guard let self, self.session?.number == number else { return }
                self.panel.showPreview(picture, forRow: position)
            }
        }
    }

    /// Back to no session: no strip, no ⌥Esc or ⌥Q, nothing polling.
    private func end(keepingPreview: Bool = false) {
        activationToken = UUID()
        opening = nil
        session = nil
        _ = focusChecks.snapshot(keeping: [])
        previewDeadline?.cancel(); previewDeadline = nil
        previewHandoff.reset()
        if !keepingPreview {
            exitingPreview = nil
            previews.end()
            highlight.hide()
        }
        poll?.invalidate()
        poll = nil
        reveal?.cancel()
        reveal = nil
        whileOpen.forEach { UnregisterEventHotKey($0) }
        whileOpen = []
        panel.hide()
    }

    // MARK: - Reading the windows

    /// Every window ⌥Tab can go to, in the order it goes to them.
    ///
    /// Every regular application is asked, not only those with a window on
    /// screen: the one whose only window is minimized has nothing on screen
    /// to be found by.
    ///
    /// **The applications are asked all at once.** Measured on this machine
    /// with ten applications showing windows: 17 ms one after the other, 8 ms
    /// together — and the first time a process speaks to each application it
    /// costs 12 to 33 ms apiece, which one after the other was 237 ms for the
    /// first ⌥Tab after launch.
    ///
    /// **And none of them is waited for longer than `patience`.** Asked all at
    /// once, the list took as long as the slowest application, and one that
    /// did not answer held every press up for the whole 250 ms timeout. That
    /// was Blender, four presses out of four while it was starting — three of
    /// them somebody's own, which is what the list's delay felt like from the
    /// keyboard. An application that is late now contributes what it said the
    /// last time it did answer, and its answer, when it comes, is kept for the
    /// next press. It cannot bring back a window that has gone: what is on
    /// screen is still decided by the WindowServer's list, which is always
    /// current, and a remembered window that is not on it is on the list only
    /// if it was minimized or hidden.
    static func read() -> (entries: [WindowSwitcher.Entry<AXWindow>],
                                   leftOut: [WindowSwitcher.Window<AXWindow>],
                                   late: [String]) {
        let census = census()
        let (windows, late) = describe(census, patience: patience)
        let (entries, leftOut) = WindowSwitcher.entries(listed: census.listed, windows: windows,
                                                        own: getpid())
        return (entries, leftOut, late)
    }

    /// How long a press waits for any one application's windows.
    ///
    /// Every warm application on this machine answers in a few milliseconds
    /// and the whole list in 7 to 37; a first conversation took up to 56. So
    /// 80 ms waits for everybody who is going to answer promptly. This runs
    /// on a worker: input remains responsive, but a late answer can still
    /// extend presentation beyond the 75 ms grace period.
    private static let patience: TimeInterval = 0.08

    private static let windowCache = SwitcherWindowCache<pid_t, [WindowSwitcher.Window<AXWindow>]>()

    /// What has to be asked on the main thread before the applications can be
    /// asked anywhere: what is on screen, and which applications to read.
    private struct Census {
        var listed: [WindowSwitcher.Listed]
        var pids: [pid_t]
        var hidden: Set<pid_t>
    }

    private struct ApplicationSnapshot {
        let regular: [pid_t]
        let hidden: Set<pid_t>
    }

    private static func applicationSnapshot() -> ApplicationSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        return ApplicationSnapshot(regular: applications.filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier), hidden: Set(applications.filter(\.isHidden).map(\.processIdentifier)))
    }

    private static func census() -> Census { census(applications: applicationSnapshot()) }

    private static func census(applications: ApplicationSnapshot) -> Census {
        let listed = listedOnScreen()
        var pids: [pid_t] = []
        var seen: Set<pid_t> = [getpid()]
        for window in listed where window.layer == 0 && seen.insert(window.pid).inserted {
            pids.append(window.pid)
        }
        for pid in applications.regular where seen.insert(pid).inserted { pids.append(pid) }
        return Census(listed: listed, pids: pids, hidden: applications.hidden)
    }

    /// Every application's windows, asked all at once from background threads,
    /// waiting at most `patience` — or for everybody, when it is `nil` — and
    /// the applications that were not waited for.
    ///
    /// An application still answering when the wait is over carries on in the
    /// background, and what it says is remembered for next time. So is every
    /// prompt answer: the memory is only ever as old as the last press.
    private static func describe(_ census: Census, patience: TimeInterval?)
        -> (windows: [WindowSwitcher.Window<AXWindow>], late: [String]) {
        let pids = census.pids
        let hidden = census.hidden
        let remembersNothing = windowCache.snapshot(keeping: Set(pids)).isEmpty
        let group = DispatchGroup()
        let requests = pids.map { pid -> DispatchGroup in
            let request = windowCache.request(pid) {
                guard let windows = AXWindow.windows(of: pid) else { return nil }
                return windows.map { window in
                    WindowSwitcher.Window(handle: window, id: window.windowID, pid: pid,
                                          subrole: window.subrole, title: window.title,
                                          isMinimized: window.isMinimized, isHidden: hidden.contains(pid))
                }
            }
            group.enter()
            request.notify(queue: .global(qos: .userInitiated)) { group.leave() }
            return request
        }
        if let patience {
            _ = group.wait(timeout: .now() + (remembersNothing ? max(patience, 0.5) : patience))
        } else {
            group.wait()
        }

        let memory = windowCache.snapshot(keeping: Set(pids))
        var windows: [WindowSwitcher.Window<AXWindow>] = []
        var late: [String] = []
        for (index, pid) in pids.enumerated() {
            let recalled = memory[pid]?.map { window -> WindowSwitcher.Window<AXWindow> in
                var window = window
                window.isHidden = hidden.contains(pid)
                return window
            }
            windows += recalled ?? []
            if requests[index].wait(timeout: .now()) == .timedOut {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                late.append(recalled == nil ? "\(name), which has not answered yet"
                                            : "\(name), as it last answered")
            }
        }
        return (windows, late)
    }

    private static func milliseconds(since start: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// What the WindowServer says is on screen, front to back.
    private static func listedOnScreen() -> [WindowSwitcher.Listed] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return WindowSwitcher.Listed(id: id,
                                         pid: pid,
                                         layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                         alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                         bounds: bounds)
        }
    }

    // MARK: - Drawing it

    /// What the panel says about each window: its title without the
    /// application's signature, and where it is — in the layout's own words,
    /// which is what tells two windows of one application apart.
    ///
    /// The screen is named too, in the line under the title, when the window
    /// is on a different one from the panel: "Centro" on the laptop and
    /// "Centro" on the monitor are two different places.
    private struct ApplicationPresentation {
        let launched: Date?
        let name: String
        let icon: NSImage?
    }

    // Reading NSRunningApplication.icon can decode a new image even when the
    // panel was already warmed. Reuse that representation across gestures,
    // and invalidate it on process restart rather than caching by PID alone.
    private static var presentations: [pid_t: ApplicationPresentation] = [:]

    static func rows(_ entries: [WindowSwitcher.Entry<AXWindow>],
                             around panelScreen: NSScreen?) -> [WindowSwitcherPanel.Row] {
        let layout = LayoutStore.shared.layout
        let severalScreens = NSScreen.screens.count > 1
        let pids = Set(entries.map(\.window.pid))
        presentations = presentations.filter { pids.contains($0.key) }
        for pid in pids {
            let application = NSRunningApplication(processIdentifier: pid)
            if presentations[pid] == nil || presentations[pid]?.launched != application?.launchDate {
                presentations[pid] = ApplicationPresentation(launched: application?.launchDate,
                    name: application?.localizedName ?? "An unnamed process", icon: application?.icon)
            }
        }
        return entries.map { entry in
            let pid = entry.window.pid
            let owner = presentations[pid]!.name
            let title = WindowSwitcher.title(entry.window.title, application: owner)

            // Said, for the windows at the end of the strip, because they are
            // there for a reason the order cannot show.
            var place = entry.window.isHidden ? "Hidden" : "Minimized"
            // Under the icon: where it is, when that is a place in the layout.
            // Otherwise its title — "Floating" under five icons in a row, as
            // the first strip had, tells five windows apart not at all.
            var zone: String?
            var elsewhere: String?
            if let bounds = entry.bounds {
                let screen = NSScreen.containing(cgPoint: CGPoint(x: bounds.midX, y: bounds.midY))
                switch screen.map({ WindowSwitcher.place(of: bounds, in: layout, area: $0.cgVisibleFrame) }) {
                case .zones(let indices)?:
                    place = WindowSwitcher.zoneLabel(indices.map { layout.zones[$0] })
                    zone = place
                case .wholeScreen?:
                    place = "Whole Screen"
                    zone = place
                case .floating?, nil:
                    place = "Floating"
                }
                if severalScreens, let screen, screen.displayID != panelScreen?.displayID {
                    elsewhere = screen.localizedName
                }
            }
            let detail = ([owner, place] + [elsewhere].compactMap { $0 }).joined(separator: " · ")
            return WindowSwitcherPanel.Row(icon: presentations[pid]?.icon, title: title, detail: detail,
                                           label: zone ?? title, isAway: entry.bounds == nil)
        }
    }

    /// The screen the window you are in is on, which is where you are looking
    /// when you press a key. The pointer's screen when nothing on the list is
    /// on screen at all.
    static func screen(for entries: [WindowSwitcher.Entry<AXWindow>]) -> NSScreen? {
        if let bounds = entries.lazy.compactMap(\.bounds).first {
            return NSScreen.containing(cgPoint: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    private static var optionIsDown: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    /// `ZTAB`, so the handler can tell these presses from the arrows'.
    private static let signature: OSType = 0x5A54_4142
}
