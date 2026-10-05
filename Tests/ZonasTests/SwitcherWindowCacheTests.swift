import Foundation
import Testing
@testable import Zonas

@Suite("Switcher opening joins window reads already started by warm-up")
struct SwitcherWindowCacheTests {
    private final class Probe {
        private let lock = NSLock()
        private var recordedGroups: [DispatchGroup] = []
        private var recordedReads = 0

        func record(_ group: DispatchGroup) {
            lock.lock(); defer { lock.unlock() }
            recordedGroups.append(group)
        }

        func read() {
            lock.lock(); defer { lock.unlock() }
            recordedReads += 1
        }

        var groups: [DispatchGroup] {
            lock.lock(); defer { lock.unlock() }
            return recordedGroups
        }

        var reads: Int {
            lock.lock(); defer { lock.unlock() }
            return recordedReads
        }
    }

    @Test("Simultaneous callers join one outstanding request and its completion")
    func concurrentRequestsJoin() throws {
        let cache = SwitcherWindowCache<Int, [String]>()
        let probe = Probe()
        let start = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let enteredRead = DispatchSemaphore(value: 0)
        let callers = DispatchGroup()
        defer { finishRead.signal() }

        for _ in 0..<2 {
            DispatchQueue.global().async(group: callers) {
                guard start.wait(timeout: .now() + 2) == .success else { return }
                let completion = cache.request(42) {
                    probe.read()
                    enteredRead.signal()
                    guard finishRead.wait(timeout: .now() + 2) == .success else { return nil }
                    return ["window"]
                }
                probe.record(completion)
            }
        }
        start.signal(); start.signal()
        #expect(callers.wait(timeout: .now() + 2) == .success)
        #expect(enteredRead.wait(timeout: .now() + 2) == .success)
        let groups = probe.groups
        #expect(groups.count == 2)
        let first = try #require(groups.first)
        let second = try #require(groups.last)
        #expect(first === second)
        #expect(probe.reads == 1)
        #expect(cache.snapshot(keeping: [42]).isEmpty)

        finishRead.signal()
        #expect(first.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42])[42] == ["window"])
    }

    @Test("A slow refresh keeps the last successful windows available")
    func pendingReadRetainsLastSuccess() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let initial = cache.request(42) { ["old window"] }
        #expect(initial.wait(timeout: .now() + 2) == .success)

        let enteredRead = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        defer { finishRead.signal() }
        let pending = cache.request(42) {
            enteredRead.signal()
            guard finishRead.wait(timeout: .now() + 2) == .success else { return nil }
            return ["new window"]
        }
        #expect(enteredRead.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42])[42] == ["old window"])
        finishRead.signal()
        #expect(pending.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42])[42] == ["new window"])
    }

    @Test("A successful empty reply removes windows that have closed")
    func successfulEmptyReplyPrunesWindows() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let initial = cache.request(42) { ["closed window"] }
        #expect(initial.wait(timeout: .now() + 2) == .success)
        let empty = cache.request(42) { [] }
        #expect(empty.wait(timeout: .now() + 2) == .success)
        let snapshot = cache.snapshot(keeping: [42])
        #expect(snapshot[42] == [])
        #expect(snapshot.count == 1)
    }

    @Test("A failed read preserves the last successful reply")
    func failureRetainsLastSuccess() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let initial = cache.request(42) { ["known window"] }
        #expect(initial.wait(timeout: .now() + 2) == .success)
        let failed = cache.request(42) { nil }
        #expect(failed.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42])[42] == ["known window"])
    }

    @Test("Failure for an unknown process does not invent an empty successful reply")
    func initialFailureRemainsUnknown() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let failed = cache.request(42) { nil }
        #expect(failed.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42]).isEmpty)
    }

    @Test("A completed failure can be retried and replaced by fresh windows")
    func retryAfterFailure() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let failed = cache.request(42) { nil }
        #expect(failed.wait(timeout: .now() + 2) == .success)
        let fresh = cache.request(42) { ["recovered window"] }
        #expect(fresh.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [42])[42] == ["recovered window"])
    }

    @Test("Exited process keys are forgotten while active processes retain their windows")
    func pruningExitedKeys() {
        let cache = SwitcherWindowCache<Int, [String]>()
        let first = cache.request(10) { ["exited process window"] }
        let second = cache.request(20) { ["active process window"] }
        #expect(first.wait(timeout: .now() + 2) == .success)
        #expect(second.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [20]) == [20: ["active process window"]])
        #expect(cache.snapshot(keeping: [10, 20])[10] == nil)
        #expect(cache.snapshot(keeping: []).isEmpty)
    }
}
