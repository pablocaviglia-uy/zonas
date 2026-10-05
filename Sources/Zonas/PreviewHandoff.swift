import CoreGraphics
import Foundation

/// Keep a preview and its geometry together while the next stream warms up.
/// Selection still changes immediately; only this visual presentation waits.
struct PreviewHandoff<Picture> {
    struct Frame {
        let window: CGWindowID?
        let bounds: CGRect
        let picture: Picture?
    }

    private struct Waiting {
        let token: UUID
        let window: CGWindowID
        let bounds: CGRect
    }

    private(set) var displayed: Frame?
    private var waiting: Waiting?
    var pendingToken: UUID? { waiting?.token }

    @discardableResult
    mutating func choose(window: CGWindowID?, bounds: CGRect?, picture: Picture?,
                         expectsPicture: Bool) -> Frame? {
        guard let bounds else { reset(); return nil }
        if expectsPicture, let window, picture == nil {
            if waiting?.window != window || waiting?.bounds != bounds {
                waiting = Waiting(token: UUID(), window: window, bounds: bounds)
            }
            return displayed
        }
        waiting = nil
        displayed = Frame(window: window, bounds: bounds, picture: picture)
        return displayed
    }

    /// A failed capture must not leave the old window highlighted indefinitely.
    /// The token also invalidates A→B→A timers, not just changes of window ID.
    @discardableResult
    mutating func fail(_ token: UUID) -> Frame? {
        guard let waiting, waiting.token == token else { return displayed }
        displayed = Frame(window: waiting.window, bounds: waiting.bounds, picture: nil)
        self.waiting = nil
        return displayed
    }

    mutating func reset() { displayed = nil; waiting = nil }
}

/// A window number alone is not enough to reuse a picture: a closed window's
/// number may later belong to another process, or the same window may resize.
struct PreviewFrameIdentity: Equatable {
    let owner: pid_t
    let size: CGSize
}

/// Recent native-resolution frames are useful on the way back through the
/// carousel, but a desktop full of large windows must not grow this indefinitely.
struct PreviewFrameCache<Picture> {
    private struct Entry {
        let picture: Picture
        let bytes: Int
        let identity: PreviewFrameIdentity?
        let capturedAt: TimeInterval
    }
    private var entries: [CGWindowID: Entry] = [:]
    private var order: [CGWindowID] = [] // least recently used first
    private(set) var bytes = 0
    let byteLimit: Int
    let countLimit: Int

    init(byteLimit: Int = 64 * 1024 * 1024, countLimit: Int = 4) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(1, countLimit)
    }

    var count: Int { entries.count }

    mutating func picture(of window: CGWindowID) -> Picture? {
        guard let entry = entries[window] else { return nil }
        order.removeAll { $0 == window }; order.append(window)
        return entry.picture
    }

    /// Validation happens at lookup, not only at a new session: a long hold
    /// must not resurrect an expired prefetch when the user comes back to it.
    mutating func picture(of window: CGWindowID, matching identity: PreviewFrameIdentity,
                          now: TimeInterval, maximumAge: TimeInterval) -> Picture? {
        guard let entry = entries[window] else { return nil }
        guard isUsable(entry, matching: identity, now: now, maximumAge: maximumAge) else {
            remove(window)
            return nil
        }
        return picture(of: window)
    }

    mutating func prune(windows: Set<CGWindowID>, identities: [CGWindowID: PreviewFrameIdentity],
                        now: TimeInterval, maximumAge: TimeInterval) {
        let expired = entries.compactMap { window, entry -> CGWindowID? in
            guard windows.contains(window), let identity = identities[window],
                  isUsable(entry, matching: identity, now: now, maximumAge: maximumAge) else { return window }
            return nil
        }
        expired.forEach { remove($0) }
    }

    private func isUsable(_ entry: Entry, matching identity: PreviewFrameIdentity,
                          now: TimeInterval, maximumAge: TimeInterval) -> Bool {
        let age = now - entry.capturedAt
        return entry.identity == identity && age.isFinite && age >= 0
            && maximumAge >= 0 && age <= maximumAge
    }

    private mutating func remove(_ window: CGWindowID) {
        if let entry = entries.removeValue(forKey: window) { bytes -= entry.bytes }
        order.removeAll { $0 == window }
    }

    mutating func store(_ picture: Picture, for window: CGWindowID, bytes cost: Int,
                        identity: PreviewFrameIdentity? = nil, capturedAt: TimeInterval = 0) {
        guard cost >= 0 else { return }
        if let previous = entries[window] { bytes -= previous.bytes }
        entries[window] = Entry(picture: picture, bytes: cost, identity: identity, capturedAt: capturedAt)
        bytes += cost
        order.removeAll { $0 == window }; order.append(window)
        // Keep one oversized current frame: discarding that too would mean
        // a large Retina window never has a picture available to present.
        while entries.count > countLimit || (bytes > byteLimit && entries.count > 1) {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { bytes -= removed.bytes }
        }
    }

    mutating func reset() { entries = [:]; order = []; bytes = 0 }
}
