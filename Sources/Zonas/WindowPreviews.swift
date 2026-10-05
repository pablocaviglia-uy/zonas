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

    /// Listing is metadata only. Coalesce overlapping refreshes, and reuse a
    /// recent list unless the current census contains a window it cannot name.
    private var listed: SCShareableContent?
    private var listing: Task<SCShareableContent?, Never>?
    private var listedAt: TimeInterval = -.infinity
    private var listingToken = UUID()
    private var windows: Set<CGWindowID> = []
    private var identities: [CGWindowID: PreviewFrameIdentity] = [:]
    private var owners: [CGWindowID: pid_t] = [:]
    private var captureGeneration = UUID()
    private var cacheExpiry: DispatchWorkItem?
    private var stillRequests: [CGWindowID: UUID] = [:]
    private var thumbnailOwners: [CGWindowID: pid_t] = [:]
    private var thumbnailIdentities: [CGWindowID: PreviewFrameIdentity] = [:]
    private var nativeRequests: [CGWindowID: NativeRequest] = [:]
    private var nativeWork = PreviewNativeWorkQueue()
    private var pendingPrefetch: Task<Void, Never>?
    private var liveRevisions: [CGWindowID: UInt64] = [:]

    /// Two seconds covers adjacent shortcut gestures, without turning an old
    /// screenshot into a long-lived substitute for a window's current content.
    private static let nativeMaximumAge: TimeInterval = 2
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A new gesture can reuse a frame captured by the last one, but can never
    /// receive a still callback from it. Only the current census supplies the
    /// ownership and geometry against which that frame is validated.
    func begin(windows: Set<CGWindowID>, owners: [CGWindowID: pid_t], identities: [CGWindowID: PreviewFrameIdentity]) {
        cacheExpiry?.cancel(); cacheExpiry = nil
        // An opening never waits for speculative construction to finish.
        // A completed, unstarted stream is validated against this census later.
        if standbyRequested != nil { cancelStandbyPreparation() }
        captureGeneration = UUID()
        pendingPrefetch?.cancel(); pendingPrefetch = nil
        stillRequests.removeAll()
        nativeWork.cancelPending()
        nativeRequests.removeAll()
        liveRevisions.removeAll()
        self.windows = windows
        self.owners = owners.filter { windows.contains($0.key) }
        self.identities = identities.filter { windows.contains($0.key) && owners[$0.key] == $0.value.owner }
        pictures = pictures.filter { window, _ in
            windows.contains(window) && thumbnailOwners[window] == self.owners[window]
                && thumbnailOwners[window] != nil
                && (self.identities[window] == nil || thumbnailIdentities[window] == self.identities[window])
        }
        thumbnailOwners = thumbnailOwners.filter { pictures[$0.key] != nil }
        thumbnailIdentities = thumbnailIdentities.filter { pictures[$0.key] != nil }
        livePictures.prune(windows: windows, identities: self.identities,
                           now: Self.now, maximumAge: Self.nativeMaximumAge)
        let known = Dictionary((listed?.windows ?? []).map { ($0.windowID, $0.owningApplication?.processID) },
                               uniquingKeysWith: { first, _ in first })
        let unknown = self.owners.contains { id, owner in known[id] != owner }
        refreshList(force: unknown)
    }

    /// Fetching shareable content never captures pixels. It is safe to prepare
    /// at launch, and a quick second gesture need not issue the same IPC twice.
    func refreshList(force: Bool = false) {
        guard listing == nil, force || Self.now - listedAt >= 0.25 else { return }
        let token = UUID()
        listingToken = token
        let fetch = Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        listing = fetch
        Task { @MainActor in
            let fresh = await fetch.value
            guard self.listingToken == token else { return }
            if let fresh { self.listed = fresh; self.listedAt = Self.now }
            self.listing = nil
        }
    }

    func end() {
        invalidateStandby()
        captureGeneration = UUID()
        pendingPrefetch?.cancel(); pendingPrefetch = nil
        nativeWork.cancelPending()
        nativeRequests.removeAll()
        stillRequests.removeAll()
        windows.removeAll()
        identities.removeAll()
        owners.removeAll()
        liveRevisions.removeAll()
        stopStream()
        // The next census validates immediate reuse. With no next gesture,
        // release the bounded native images too, rather than keeping them until
        // somebody happens to look up an expired entry.
        cacheExpiry?.cancel()
        let generation = captureGeneration
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.captureGeneration == generation, self.windows.isEmpty else { return }
            self.livePictures.reset()
            self.cacheExpiry = nil
        }
        cacheExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.nativeMaximumAge, execute: expiry)
    }

    func picture(of window: CGWindowID) -> NSImage? { pictures[window] }

    /// Join the selected window's native fallback instead of taking a second
    /// screenshot merely to downsize it for the carousel. Large images are not
    /// put in the thumbnail dictionary: that would defeat the native LRU limit.
    func capture(_ window: CGWindowID, size: CGSize?, fitting box: CGSize, scale: CGFloat,
                 then deliver: @escaping (NSImage) -> Void) {
        guard windows.contains(window), let owner = owners[window], box.width > 0 else { return }
        if let picture = livePicture(of: window) { deliver(picture); return }
        if let request = nativeRequests[window] {
            request.callbacks.append { picture in if let picture { deliver(picture) } }
            return
        }
        guard stillRequests[window] == nil else { return }
        let token = UUID()
        let identity = identities[window]
        let ticket = PreviewCaptureTicket(session: captureGeneration, request: token, window: window, owner: owner, identity: identity)
        stillRequests[window] = token
        Task { @MainActor in
            let target = await self.target(window, owner: owner)
            guard ticket.isCurrent(session: self.captureGeneration, request: self.stillRequests[window],
                                   windows: self.windows, owners: self.owners, identities: self.identities) else { return }
            let picture: NSImage?
            if let target {
                picture = await Self.take(target, size: size ?? target.frame.size, fitting: box, scale: scale)
            } else { picture = nil }
            guard ticket.isCurrent(session: self.captureGeneration, request: self.stillRequests[window],
                                   windows: self.windows, owners: self.owners, identities: self.identities) else { return }
            self.stillRequests.removeValue(forKey: window)
            guard let picture else { return }
            self.pictures[window] = picture
            self.thumbnailOwners[window] = owner
            self.thumbnailIdentities[window] = identity
            deliver(picture)
        }
    }

    private var livePictures = PreviewFrameCache<NSImage>()
    private var liveStream: SCStream?
    private var liveOutput: LivePreviewOutput?
    private var streamPreparation: Task<PreparedLiveStream, Error>?
    private var liveWindow: CGWindowID?
    private var streamGeneration = UUID()
    private var failedWindow: CGWindowID?
    private var standby = PreviewStandbyCache<PreparedLiveStream>()
    private var standbyRequested: PreviewStandbyIdentity?
    private var standbyPreparation: Task<PreparedLiveStream, Error>?
    private var standbyToken = UUID()
    private var standbyReadyToken = UUID()
    private var standbyExpiry: DispatchWorkItem?
    private var standbyPendingExpiry: DispatchWorkItem?
    private static let standbyMaximumAge: TimeInterval = 30
    private static let standbyRenewAfter: TimeInterval = 15
    // Apple describes CIContext as heavyweight and recommends reusing it. A
    // fresh context and output queue for every Tab threw that preparation away.
    private let conversionContext = CIContext()
    private let outputQueue = DispatchQueue(label: "uy.com.fcstudio.zonas.preview", qos: .userInitiated)

    func livePicture(of window: CGWindowID) -> NSImage? {
        guard let identity = identities[window], owners[window] == identity.owner else { return nil }
        return livePictures.picture(of: window, matching: identity,
                                    now: Self.now, maximumAge: Self.nativeMaximumAge)
    }

    func liveCaptureFailed(for window: CGWindowID) -> Bool { failedWindow == window }

    func stopStream() {
        streamPreparation?.cancel(); streamPreparation = nil
        pendingPrefetch?.cancel(); pendingPrefetch = nil
        let obsolete = nativeWork.cancelPending()
        nativeRequests = nativeRequests.filter { !obsolete.contains($0.value.token) }
        streamGeneration = UUID()
        liveWindow = nil
        let old = liveStream
        liveStream = nil
        liveOutput?.invalidate()
        liveOutput = nil
        failedWindow = nil
        if let old { Task { try? await old.stopCapture() } }
    }

    /// Build one likely next stream while idle, without starting capture or
    /// creating a screenshot. Apple separates stream construction from capture;
    /// this moves constructor cost away from the gesture, not compositor startup.
    func prepareStandby(window: CGWindowID, owner: pid_t, bounds: CGRect) {
        let identity = PreviewStandbyIdentity(window: window, owner: owner, bounds: bounds)
        guard identity.isValid, windows.isEmpty, liveWindow == nil,
              Self.isAllowed, Self.isInRing() else {
            invalidateStandby()
            return
        }
        if let pending = standbyRequested, pending != identity { cancelStandbyPreparation() }
        if let age = standby.age(of: identity, now: Self.now), age < Self.standbyRenewAfter { return }
        guard standbyRequested != identity else { return }
        // Keep the last ready stream while its replacement is prepared. Its
        // original expiry still applies, and an opening cancels only the worker.
        cancelStandbyPreparation()
        let token = standbyToken
        standbyRequested = identity
        let pendingExpiry = DispatchWorkItem { [weak self] in
            guard let self, self.standbyToken == token else { return }
            self.cancelStandbyPreparation()
        }
        standbyPendingExpiry = pendingExpiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.standbyMaximumAge, execute: pendingExpiry)
        Task { @MainActor in
            let lookupBegan = Self.now
            let target = await self.target(window, owner: owner)
            guard self.canPrepareStandby(identity, token: token) else { return }
            guard let target else { self.cancelStandbyPreparation(); return }
            let lookupMS = Int((Self.now - lookupBegan) * 1000)
            let context = self.conversionContext
            let queue = self.outputQueue
            let queuedAt = Self.now
            let preparation = Task.detached(priority: .utility) {
                try Self.prepareLiveStream(target, size: bounds.size, context: context,
                                           queue: queue, queuedAt: queuedAt)
            }
            self.standbyPreparation = preparation
            do {
                let prepared = try await preparation.value
                guard self.canPrepareStandby(identity, token: token),
                      Self.now - prepared.completedAt <= Self.standbyMaximumAge else {
                    prepared.output.invalidate()
                    return
                }
                self.cancelStandbyPreparation()
                self.standby.store(prepared, identity: identity, preparedAt: prepared.completedAt)?.output.invalidate()
                self.standbyReadyToken = UUID()
                self.expireStandby(token: self.standbyReadyToken,
                                   after: Self.standbyMaximumAge - (Self.now - prepared.completedAt))
                Log.write("windows: live preview standby ready for \(window) without capture"
                          + " (lookup \(lookupMS) ms, worker queue \(prepared.queuedMS) ms, constructors \(prepared.milliseconds) ms)")
            } catch {
                guard self.standbyToken == token else { return }
                self.cancelStandbyPreparation()
                if !(error is CancellationError) {
                    Log.write("windows: live preview standby preparation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Disable, wake and display changes invalidate speculative metadata too.
    /// No started stream is ever returned to this single-consumption slot.
    func invalidateStandby() {
        cancelStandbyPreparation()
        standbyReadyToken = UUID()
        standby.remove()?.output.invalidate()
        standbyExpiry?.cancel(); standbyExpiry = nil
    }

    private func cancelStandbyPreparation() {
        standbyToken = UUID()
        standbyPreparation?.cancel(); standbyPreparation = nil
        standbyRequested = nil
        standbyPendingExpiry?.cancel(); standbyPendingExpiry = nil
    }

    private func canPrepareStandby(_ identity: PreviewStandbyIdentity, token: UUID) -> Bool {
        standbyToken == token && standbyRequested == identity && windows.isEmpty && liveWindow == nil
            && Self.isAllowed && Self.isInRing()
    }

    private func expireStandby(token: UUID, after interval: TimeInterval) {
        standbyExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.standbyReadyToken == token else { return }
            self.standby.remove()?.output.invalidate()
            self.standbyReadyToken = UUID()
            self.standbyExpiry = nil
        }
        standbyExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval), execute: expiry)
    }

    /// Only the selected window streams. A native still wins the cold-start
    /// race when it can; a newer live frame always wins over that still.
    func stream(_ window: CGWindowID, bounds: CGRect,
                then update: @escaping () -> Void) {
        let size = bounds.size
        let standbyIdentity = PreviewStandbyIdentity(window: window, owner: owners[window] ?? 0, bounds: bounds)
        guard liveWindow != window, let identity = identities[window], identity.size == size,
              standbyIdentity.isValid else { return }
        let consumed = standby.take(matching: standbyIdentity, now: Self.now, maximumAge: Self.standbyMaximumAge)
        let ready: PreparedLiveStream?
        if let consumed, consumed.matches {
            ready = consumed.value
            Log.write("windows: live preview standby reused for \(window)")
        } else {
            consumed?.value.output.invalidate()
            ready = nil
        }
        invalidateStandby()
        stopStream()
        liveWindow = window
        let generation = streamGeneration
        let began = Self.now
        var firstFrame = true
        if livePicture(of: window) != nil {
            Log.write("windows: native preview cache hit for \(window)")
        } else {
            requestNative(window, identity: identity, isPrefetch: false) { picture in
                if picture != nil { update() }
            }
        }
        Task { @MainActor in
            let deliver: (CGImage) -> Void = { [weak self] image in
                guard let self, self.streamGeneration == generation,
                      self.identities[window] == identity, self.owners[window] == identity.owner else { return }
                if firstFrame {
                    firstFrame = false
                    Log.write("windows: live preview first frame for \(window) after \(Int((Self.now - began) * 1000)) ms")
                }
                self.liveRevisions[window, default: 0] += 1
                self.livePictures.store(NSImage(cgImage: image, size: size), for: window,
                                        bytes: image.bytesPerRow * image.height,
                                        identity: identity, capturedAt: Self.now)
                update()
            }
            do {
                let prepared: PreparedLiveStream
                if let ready { prepared = ready }
                else {
                    let lookupBegan = Self.now
                    let cachedTarget = self.listed?.windows.contains {
                        $0.windowID == window && $0.owningApplication?.processID == identity.owner
                    } ?? false
                    let target = await self.target(window, owner: identity.owner)
                    guard self.streamGeneration == generation, self.identities[window] == identity else { return }
                    Log.write("windows: live preview lookup for \(window) in \(Int((Self.now - lookupBegan) * 1000)) ms"
                              + " (main queue \(Int((lookupBegan - began) * 1000)) ms, \(cachedTarget ? "cached" : "refreshed") metadata)")
                    guard let target else {
                        self.failedWindow = window
                        self.liveWindow = nil
                        Log.write("windows: live preview unavailable for window \(window)")
                        update()
                        return
                    }
                    let context = self.conversionContext
                    let queue = self.outputQueue
                    let queuedAt = Self.now
                    let preparation = Task.detached(priority: .userInitiated) {
                        try Self.prepareLiveStream(target, size: size, context: context,
                                                   queue: queue, queuedAt: queuedAt)
                    }
                    self.streamPreparation = preparation
                    prepared = try await preparation.value
                }
                guard self.streamGeneration == generation, self.identities[window] == identity,
                      self.owners[window] == identity.owner else {
                    prepared.output.invalidate()
                    return
                }
                self.streamPreparation = nil
                prepared.output.arm(deliver)
                if ready == nil {
                    Log.write("windows: live preview prepared for \(window) off the main thread in \(prepared.milliseconds) ms"
                              + " (worker queue \(prepared.queuedMS) ms, adoption \(Int((Self.now - prepared.completedAt) * 1000)) ms,"
                              + " filter \(prepared.filterMS) ms, config \(prepared.configMS) ms,"
                              + " stream \(prepared.streamMS) ms, output \(prepared.outputMS) ms)")
                }
                self.liveStream = prepared.stream
                self.liveOutput = prepared.output
                let starting = Self.now
                try await prepared.stream.startCapture()
                if self.streamGeneration != generation {
                    prepared.output.invalidate()
                    try? await prepared.stream.stopCapture()
                } else {
                    Log.write("windows: live preview startCapture completed for \(window) in \(Int((Self.now - starting) * 1000)) ms")
                }
            } catch is CancellationError {
                // Moving past a window is cancellation, not capture failure.
                return
            } catch {
                guard self.streamGeneration == generation else { return }
                self.stopStream()
                self.failedWindow = window
                update()
                Log.write("windows: live preview failed: \(error.localizedDescription)")
            }
        }
    }

    private struct PreparedLiveStream {
        let stream: SCStream
        let output: LivePreviewOutput
        let milliseconds: Int
        let queuedMS: Int
        let filterMS: Int
        let configMS: Int
        let streamMS: Int
        let outputMS: Int
        let completedAt: TimeInterval
    }

    /// ScreenCaptureKit's constructors/registering an output do synchronous
    /// work before startCapture's async boundary. They have no UI affinity in
    /// the SDK, and each object is transferred exclusively after preparation.
    /// AppKit state and frame delivery still belong to the main thread.
    private static func prepareLiveStream(_ target: SCWindow, size: CGSize, context: CIContext,
                                          queue: DispatchQueue, queuedAt: TimeInterval) throws -> PreparedLiveStream {
        try Task.checkCancellation()
        let began = Self.now
        let filter = SCContentFilter(desktopIndependentWindow: target)
        try Task.checkCancellation()
        let scale = CGFloat(filter.pointPixelScale)
        let configuredAt = Self.now
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        // Source scale plus scalesToFit prevents a 1x source occupying
        // only the upper-left quarter of a 2x preview buffer.
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let output = LivePreviewOutput(context: context)
        let streamBegan = Self.now
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try Task.checkCancellation()
        let outputBegan = Self.now
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        let completedAt = Self.now
        return PreparedLiveStream(stream: stream, output: output,
                                  milliseconds: Int((completedAt - began) * 1000),
                                  queuedMS: Int((began - queuedAt) * 1000),
                                  filterMS: Int((configuredAt - began) * 1000),
                                  configMS: Int((streamBegan - configuredAt) * 1000),
                                  streamMS: Int((outputBegan - streamBegan) * 1000),
                                  outputMS: Int((completedAt - outputBegan) * 1000),
                                  completedAt: completedAt)
    }

    /// Only a neighbor of the explicit current gesture is captured. Delay its
    /// lower-priority request so it does not race the selected first picture.
    func prefetchNative(_ window: CGWindowID, size: CGSize) {
        pendingPrefetch?.cancel()
        guard liveWindow != nil, window != liveWindow,
              let identity = identities[window], identity.size == size,
              livePicture(of: window) == nil else { pendingPrefetch = nil; return }
        let generation = captureGeneration
        pendingPrefetch = Task(priority: .utility) { @MainActor in
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            guard !Task.isCancelled, self.captureGeneration == generation,
                  self.identities[window] == identity, self.liveWindow != nil else { return }
            self.requestNative(window, identity: identity, isPrefetch: true) { _ in }
        }
    }

    private final class NativeRequest {
        let token = UUID()
        let session: UUID
        let stream: UUID
        let identity: PreviewFrameIdentity
        let revision: UInt64
        var isPrefetch: Bool
        let began: TimeInterval
        var callbacks: [(NSImage?) -> Void]
        init(session: UUID, stream: UUID, identity: PreviewFrameIdentity, revision: UInt64, isPrefetch: Bool,
             began: TimeInterval, callback: @escaping (NSImage?) -> Void) {
            self.session = session; self.stream = stream; self.identity = identity; self.revision = revision
            self.isPrefetch = isPrefetch; self.began = began; callbacks = [callback]
        }
    }

    private func requestNative(_ window: CGWindowID, identity: PreviewFrameIdentity,
                               isPrefetch: Bool, then callback: @escaping (NSImage?) -> Void) {
        guard windows.contains(window), identities[window] == identity, owners[window] == identity.owner else { return }
        if let picture = livePicture(of: window) { callback(picture); return }
        let request: NativeRequest
        if let pending = nativeRequests[window], pending.identity == identity {
            pending.callbacks.append(callback)
            if !isPrefetch { pending.isPrefetch = false }
            request = pending
        } else {
            request = NativeRequest(session: captureGeneration, stream: streamGeneration, identity: identity,
                                    revision: liveRevisions[window, default: 0], isPrefetch: isPrefetch,
                                    began: Self.now, callback: callback)
            nativeRequests[window] = request
        }
        let discarded = nativeWork.enqueue(request.token, selected: !request.isPrefetch)
        nativeRequests = nativeRequests.filter { !discarded.contains($0.value.token) }
        startQueuedNative()
    }

    private func startQueuedNative() {
        while let token = nativeWork.takeNext() {
            guard let (window, request) = nativeRequests.first(where: { $0.value.token == token }) else {
                nativeWork.finish(token)
                continue
            }
            performNative(window, request: request)
        }
    }

    private func performNative(_ window: CGWindowID, request: NativeRequest) {
        let identity = request.identity
        let ticket = PreviewCaptureTicket(session: request.session, request: request.token,
                                          window: window, owner: identity.owner, identity: identity)
        let submittedAt = Self.now
        Task(priority: request.isPrefetch ? .utility : .userInitiated) { @MainActor in
            defer {
                self.nativeWork.finish(request.token)
                self.startQueuedNative()
            }
            let lookupBegan = Self.now
            let target = await self.target(window, owner: identity.owner)
            let lookupMS = Int((Self.now - lookupBegan) * 1000)
            guard ticket.isCurrent(session: self.captureGeneration, request: self.nativeRequests[window]?.token,
                                   windows: self.windows, owners: self.owners, identities: self.identities) else { return }
            // A slot may have been occupied only by shareable-content lookup;
            // do not submit pixels for a selection/neighbor that moved on while
            // that lookup was awaiting IPC.
            guard request.isPrefetch ? request.stream == self.streamGeneration : self.liveWindow == window else {
                self.nativeRequests.removeValue(forKey: window)
                return
            }
            if let picture = self.livePicture(of: window) {
                self.nativeRequests.removeValue(forKey: window)
                request.callbacks.forEach { $0(picture) }
                return
            }
            let captured: NativeCapture?
            if let target { captured = await Self.takeNative(target, size: identity.size) }
            else { captured = nil }
            guard ticket.isCurrent(session: self.captureGeneration, request: self.nativeRequests[window]?.token,
                                   windows: self.windows, owners: self.owners, identities: self.identities) else { return }
            self.nativeRequests.removeValue(forKey: window)
            if let captured {
                let newerLiveFrame = self.liveRevisions[window, default: 0] != request.revision
                if !newerLiveFrame {
                    self.livePictures.store(captured.picture, for: window, bytes: captured.bytes,
                                            identity: identity, capturedAt: Self.now)
                }
                let kind = request.isPrefetch ? "prefetch" : "fallback"
                Log.write("windows: native preview \(kind) for \(window) after \(Int((Self.now - request.began) * 1000)) ms"
                          + " (scheduler \(Int((submittedAt - request.began) * 1000)) ms,"
                          + " main queue \(Int((lookupBegan - submittedAt) * 1000)) ms, lookup \(lookupMS) ms,"
                          + " setup \(captured.setupMS) ms, captureImage \(captured.captureMS) ms"
                          + (newerLiveFrame ? ", newer live frame kept)" : ")"))
            }
            let picture = self.livePicture(of: window)
            request.callbacks.forEach { $0(picture) }
        }
    }

    /// A cached SCWindow must agree with the census owner, including minimized
    /// windows whose native-frame identity has no known geometry.
    @MainActor
    private func target(_ window: CGWindowID, owner: pid_t) async -> SCWindow? {
        if let target = listed?.windows.first(where: { $0.windowID == window }),
           target.owningApplication?.processID == owner { return target }
        refreshList(force: true)
        guard let target = await listing?.value?.windows.first(where: { $0.windowID == window }),
              target.owningApplication?.processID == owner else { return nil }
        return target
    }

    private struct NativeCapture {
        let picture: NSImage
        let bytes: Int
        let setupMS: Int
        let captureMS: Int
    }

    private static func takeNative(_ window: SCWindow, size: CGSize) async -> NativeCapture? {
        let began = Self.now
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * CGFloat(filter.pointPixelScale)))
        config.height = max(1, Int(size.height * CGFloat(filter.pointPixelScale)))
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let captureBegan = Self.now
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NativeCapture(picture: NSImage(cgImage: image, size: size), bytes: image.bytesPerRow * image.height,
                             setupMS: Int((captureBegan - began) * 1000), captureMS: Int((Self.now - captureBegan) * 1000))
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
    private let context: CIContext
    private var deliver: ((CGImage) -> Void)?
    private let frames = PreviewLatestFrame<CGImage>()

    init(context: CIContext) { self.context = context }

    /// An unstarted standby cannot carry a previous gesture's delivery closure.
    /// Arming and eventual delivery both happen on the main thread.
    @MainActor
    func arm(_ deliver: @escaping (CGImage) -> Void) { self.deliver = deliver }

    func invalidate() { frames.invalidate() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard frames.isActive, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(frame, from: frame.extent), frames.offer(image) else { return }
        DispatchQueue.main.async {
            guard let image = self.frames.take() else { return }
            self.deliver?(image)
        }
    }
}

/// Still requests are not cancellable at the compositor once submitted. Their
/// lease must therefore survive every await and reject completion after close,
/// reopen, a new request for the same ID, or changed window ownership/geometry.
struct PreviewCaptureTicket {
    let session: UUID
    let request: UUID
    let window: CGWindowID
    let owner: pid_t
    let identity: PreviewFrameIdentity?

    func isCurrent(session currentSession: UUID, request currentRequest: UUID?,
                   windows: Set<CGWindowID>, owners: [CGWindowID: pid_t],
                   identities: [CGWindowID: PreviewFrameIdentity]) -> Bool {
        session == currentSession && request == currentRequest && windows.contains(window)
            && owner == owners[window] && identity == identities[window]
    }
}

/// The renderer wants the newest frame, not a queue of screenshots from before
/// an Accessibility call blocked the main thread. One delivery holds one slot;
/// replacements release intermediate images even while that delivery is queued.
final class PreviewLatestFrame<Frame> {
    private let lock = NSLock()
    private var active = true
    private var scheduled = false
    private var pending: Frame?

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    /// True schedules the one main-thread delivery; false either replaces its
    /// pending frame or rejects an inactive stream.
    func offer(_ frame: Frame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        pending = frame
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        guard active else { pending = nil; return nil }
        let frame = pending
        pending = nil
        return frame
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false
        pending = nil
    }
}

/// Keep submitted compositor work bounded even across closing/reopening. A
/// submitted screenshot cannot be taken back; only the newest selected request
/// and newest neighbor may wait behind the two occupied slots.
struct PreviewNativeWorkQueue {
    private(set) var running: Set<UUID> = []
    private var prefetching: Set<UUID> = []
    private(set) var selected: UUID?
    private(set) var neighbor: UUID?

    /// Return replaced pending tokens so their subscribers can be discarded.
    mutating func enqueue(_ token: UUID, selected isSelected: Bool) -> [UUID] {
        if running.contains(token) {
            if isSelected { prefetching.remove(token) }
            return []
        }
        if isSelected {
            let old = selected
            selected = token
            if neighbor == token { neighbor = nil }
            return old == nil || old == token ? [] : [old!]
        }
        guard selected != token else { return [] }
        let old = neighbor
        neighbor = token
        return old == nil || old == token ? [] : [old!]
    }

    mutating func takeNext() -> UUID? {
        guard running.count < 2 else { return nil }
        let token: UUID
        if let next = selected { token = next; selected = nil }
        else if let next = neighbor, prefetching.isEmpty {
            token = next; neighbor = nil; prefetching.insert(token)
        } else { return nil }
        running.insert(token)
        return token
    }

    mutating func finish(_ token: UUID) { running.remove(token); prefetching.remove(token) }

    @discardableResult
    mutating func cancelPending() -> [UUID] {
        let cancelled = [selected, neighbor].compactMap { $0 }
        selected = nil; neighbor = nil
        return cancelled
    }
}

/// A prepared stream belongs to one exact census entry. Bounds include position:
/// moving between displays can change source scale even when the size matches.
struct PreviewStandbyIdentity: Equatable {
    let window: CGWindowID
    let owner: pid_t
    let bounds: CGRect

    var isValid: Bool {
        window != kCGNullWindowID && owner > 0
            && bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.size.width.isFinite && bounds.size.height.isFinite
            && bounds.size.width > 0 && bounds.size.height > 0
    }
}

/// There is room for one unstarted stream, and every lookup consumes it. A
/// mismatched or expired stream cannot become a later gesture's fallback.
struct PreviewStandbyCache<Value> {
    private struct Entry {
        let identity: PreviewStandbyIdentity
        let value: Value
        let preparedAt: TimeInterval
    }
    struct Taken {
        let value: Value
        let matches: Bool
    }
    private var entry: Entry?
    var count: Int { entry == nil ? 0 : 1 }

    func age(of identity: PreviewStandbyIdentity, now: TimeInterval) -> TimeInterval? {
        guard let entry, identity.isValid, entry.identity == identity else { return nil }
        let age = now - entry.preparedAt
        return age.isFinite && age >= 0 ? age : nil
    }

    func contains(_ identity: PreviewStandbyIdentity, now: TimeInterval, maximumAge: TimeInterval) -> Bool {
        guard let age = age(of: identity, now: now) else { return false }
        return maximumAge.isFinite && maximumAge >= 0 && age <= maximumAge
    }

    @discardableResult
    mutating func store(_ value: Value, identity: PreviewStandbyIdentity, preparedAt: TimeInterval) -> Value? {
        let previous = entry?.value
        entry = Entry(identity: identity, value: value, preparedAt: preparedAt)
        return previous
    }

    mutating func take(matching identity: PreviewStandbyIdentity, now: TimeInterval, maximumAge: TimeInterval) -> Taken? {
        guard let entry else { return nil }
        self.entry = nil
        return Taken(value: entry.value, matches: matches(entry, identity: identity, now: now, maximumAge: maximumAge))
    }

    @discardableResult
    mutating func remove() -> Value? {
        let previous = entry?.value
        entry = nil
        return previous
    }

    private func matches(_ entry: Entry, identity: PreviewStandbyIdentity,
                         now: TimeInterval, maximumAge: TimeInterval) -> Bool {
        let age = now - entry.preparedAt
        return identity.isValid && entry.identity == identity && age.isFinite && age >= 0
            && maximumAge.isFinite && maximumAge >= 0 && age <= maximumAge
    }
}
