import Foundation

/// Keeps preparation out of a switcher's gesture, coalesces changes to the
/// desktop, and rejects a background answer from before sleep or disable.
/// A cancelled pass still occupies its slot until its worker actually returns.
struct SwitcherIdleReadiness {
    static let coalescingDelay: TimeInterval = 0.25
    static let refreshInterval: TimeInterval = 20
    static let timerTolerance: TimeInterval = 5

    struct Ticket: Equatable {
        fileprivate let token = UUID()
        fileprivate let generation: UUID
    }

    private(set) var enabled = false
    private(set) var isAwake = true
    private(set) var deadline: TimeInterval?
    private(set) var inFlight: Ticket?
    private var generation = UUID()

    mutating func setEnabled(_ value: Bool, at now: TimeInterval) {
        guard value != enabled else { return }
        enabled = value
        invalidate(at: now)
    }

    mutating func setAwake(_ value: Bool, at now: TimeInterval) {
        guard value != isAwake else { return }
        isAwake = value
        invalidate(at: now)
    }

    /// Changes arriving together get one pass after the last change. A busy
    /// gesture or worker leaves that request pending rather than losing it.
    mutating func request(at now: TimeInterval) {
        guard enabled, isAwake else { return }
        if inFlight != nil { generation = UUID() }
        deadline = now + Self.coalescingDelay
    }

    mutating func begin(at now: TimeInterval, isBusy: Bool) -> Ticket? {
        guard enabled, isAwake, !isBusy, inFlight == nil,
              let deadline, now >= deadline else { return nil }
        let ticket = Ticket(generation: generation)
        self.deadline = nil
        inFlight = ticket
        return ticket
    }

    /// Returning false means the result must not be applied. Even a stale
    /// completion releases its own physical slot, but never another pass's.
    mutating func complete(_ ticket: Ticket) -> Bool {
        guard inFlight == ticket else { return false }
        inFlight = nil
        return enabled && isAwake && ticket.generation == generation
    }

    private mutating func invalidate(at now: TimeInterval) {
        generation = UUID()
        deadline = nil
        request(at: now)
    }
}
