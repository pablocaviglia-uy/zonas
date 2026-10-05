import Testing
@testable import Zonas

@Suite("Switcher readiness stays idle and rejects cancelled work")
struct SwitcherIdleReadinessTests {
    @Test("Disabled preparation ignores changes")
    func disabled() {
        var readiness = SwitcherIdleReadiness()
        readiness.request(at: 1)
        #expect(readiness.deadline == nil)
        let attempt = readiness.begin(at: 10, isBusy: false)
        #expect(attempt == nil)
    }

    @Test("Enabling schedules preparation after the coalescing delay")
    func enabled() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 1)
        #expect(readiness.deadline == 1.25)
        let early = readiness.begin(at: 1.24, isBusy: false)
        #expect(early == nil)
        let started = readiness.begin(at: 1.25, isBusy: false)
        let ticket = try #require(started)
        #expect(readiness.deadline == nil)
        #expect(readiness.inFlight == ticket)
        let accepted = readiness.complete(ticket)
        #expect(accepted)
        #expect(readiness.inFlight == nil)
    }

    @Test("Application and display changes coalesce after their latest event")
    func changesCoalesce() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        readiness.request(at: 0.125)
        readiness.request(at: 0.25)
        #expect(readiness.deadline == 0.5)
        let early = readiness.begin(at: 0.375, isBusy: false)
        #expect(early == nil)
        let due = readiness.begin(at: 0.5, isBusy: false)
        _ = try #require(due)
    }

    @Test("A gesture keeps due preparation pending until the switcher is idle")
    func busyGesture() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        let busy = readiness.begin(at: 1, isBusy: true)
        #expect(busy == nil)
        #expect(readiness.deadline == 0.25)
        let idle = readiness.begin(at: 2, isBusy: false)
        _ = try #require(idle)
    }

    @Test("A request arriving during preparation gets one later pass")
    func requestDuringRead() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        let firstRequest = readiness.begin(at: 0.25, isBusy: false)
        let first = try #require(firstRequest)
        readiness.request(at: 1)
        readiness.request(at: 1.25)
        let overlap = readiness.begin(at: 2, isBusy: false)
        #expect(overlap == nil)
        let accepted = readiness.complete(first)
        #expect(!accepted)
        let nextRequest = readiness.begin(at: 2, isBusy: false)
        let second = try #require(nextRequest)
        #expect(second != first)
        #expect(readiness.deadline == nil)
    }

    @Test("Disabling cancels scheduled preparation")
    func disableBeforeRead() {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        readiness.setEnabled(false, at: 0.125)
        #expect(readiness.deadline == nil)
        let attempt = readiness.begin(at: 1, isBusy: false)
        #expect(attempt == nil)
    }

    @Test("Disabling rejects an old result without starting a second worker")
    func disableDuringRead() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        let firstRequest = readiness.begin(at: 0.25, isBusy: false)
        let first = try #require(firstRequest)
        readiness.setEnabled(false, at: 0.5)
        readiness.setEnabled(true, at: 1)
        #expect(readiness.inFlight == first)
        let overlap = readiness.begin(at: 1.25, isBusy: false)
        #expect(overlap == nil)
        let accepted = readiness.complete(first)
        #expect(!accepted)
        let nextRequest = readiness.begin(at: 1.25, isBusy: false)
        _ = try #require(nextRequest)
    }

    @Test("Sleep cancels queued work and wake schedules a fresh pass")
    func sleepBeforeRead() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        readiness.setAwake(false, at: 0.125)
        readiness.request(at: 1)
        #expect(readiness.deadline == nil)
        let whileAsleep = readiness.begin(at: 1, isBusy: false)
        #expect(whileAsleep == nil)
        readiness.setAwake(true, at: 2)
        #expect(readiness.deadline == 2.25)
        let afterWake = readiness.begin(at: 2.25, isBusy: false)
        _ = try #require(afterWake)
    }

    @Test("Wake cannot overlap the worker started before sleep")
    func sleepDuringRead() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        let firstRequest = readiness.begin(at: 0.25, isBusy: false)
        let first = try #require(firstRequest)
        readiness.setAwake(false, at: 0.5)
        readiness.setAwake(true, at: 1)
        let overlap = readiness.begin(at: 2, isBusy: false)
        #expect(overlap == nil)
        let accepted = readiness.complete(first)
        #expect(!accepted)
        let afterWake = readiness.begin(at: 2, isBusy: false)
        _ = try #require(afterWake)
    }

    @Test("Enabling while asleep waits for wake")
    func enableWhileAsleep() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setAwake(false, at: 0)
        readiness.setEnabled(true, at: 1)
        #expect(readiness.deadline == nil)
        let whileAsleep = readiness.begin(at: 2, isBusy: false)
        #expect(whileAsleep == nil)
        readiness.setAwake(true, at: 3)
        let afterWake = readiness.begin(at: 3.25, isBusy: false)
        _ = try #require(afterWake)
    }

    @Test("An old duplicate completion cannot release a newer worker")
    func staleCompletion() throws {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        let firstRequest = readiness.begin(at: 0.25, isBusy: false)
        let first = try #require(firstRequest)
        let firstAccepted = readiness.complete(first)
        #expect(firstAccepted)
        readiness.request(at: 1)
        let nextRequest = readiness.begin(at: 1.25, isBusy: false)
        let second = try #require(nextRequest)
        let duplicateAccepted = readiness.complete(first)
        #expect(!duplicateAccepted)
        #expect(readiness.inFlight == second)
        let secondAccepted = readiness.complete(second)
        #expect(secondAccepted)
    }

    @Test("Repeated state notifications do not postpone scheduled preparation")
    func repeatedLifecycleState() {
        var readiness = SwitcherIdleReadiness()
        readiness.setEnabled(true, at: 0)
        readiness.setEnabled(true, at: 0.125)
        readiness.setAwake(true, at: 0.125)
        #expect(readiness.deadline == 0.25)
    }
}
