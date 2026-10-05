import Foundation
import Testing
@testable import Zonas

@Suite("Known switcher windows do not wait for unrelated slow applications")
struct SwitcherInventoryReadTests {
    private let own: pid_t = 99
    private func window(_ id: UInt32?, pid: pid_t = 1) -> WindowSwitcher.Window<String> {
        .init(handle: "handle", id: id, pid: pid, subrole: "AXStandardWindow", title: "Window")
    }
    private func listed(_ id: UInt32, pid: pid_t = 1, layer: Int = 0, alpha: Double = 1,
                        bounds: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300)) -> WindowSwitcher.Listed {
        .init(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
    }
    private func budget(_ visible: [WindowSwitcher.Listed], _ memory: [pid_t: [WindowSwitcher.Window<String>]],
                        pids: [pid_t] = [1], hidden: Set<pid_t> = [], recent: Set<pid_t> = [], fresh: Bool = false,
                        patience: TimeInterval? = 0.08) -> TimeInterval? {
        SwitcherInventoryRead.budget(listed: visible, memory: memory, pids: pids, hidden: hidden, recent: recent,
            own: own, patience: patience, waitingForFresh: fresh)
    }

    @Test("Every visible ID and owner already known uses the short budget")
    func knownWindows() {
        #expect(budget([listed(10), listed(20, pid: 2)], [1: [window(10)], 2: [window(20, pid: 2)]], pids: [1, 2]) == 0.008)
    }

    @Test("Initial missing metadata keeps the cold discovery budget")
    func coldOpening() {
        #expect(budget([listed(10)], [:]) == 0.5)
    }

    @Test("A newly opened window gets the regular discovery budget")
    func newlyOpenedWindow() {
        #expect(budget([listed(10), listed(11)], [1: [window(10)]]) == 0.08)
    }

    @Test("A newly launched hidden owner is also discovered")
    func newOwnerWithoutVisibleWindow() {
        #expect(budget([listed(10)], [1: [window(10)]], pids: [1, 2], hidden: [2]) == 0.08)
    }

    @Test("Window IDs cannot borrow another owner's metadata")
    func ownerMismatch() {
        #expect(budget([listed(10)], [1: [window(10, pid: 2)]]) == 0.08)
        #expect(budget([listed(10, pid: 2)], [1: [window(10)], 2: []], pids: [1, 2]) == 0.08)
    }

    @Test("A successful empty reply is known metadata")
    func emptyReply() {
        #expect(budget([listed(10)], [1: [window(10)], 2: []], pids: [1, 2]) == 0.008)
        #expect(budget([], [1: []]) == 0.008)
    }

    @Test("Untitled palettes already described do not force rediscovery")
    func knownUnswitchableWindow() {
        let palette = WindowSwitcher.Window(handle: "palette", id: UInt32(10), pid: pid_t(1),
                                           subrole: "AXDialog", title: "")
        #expect(budget([listed(10)], [1: [palette]]) == 0.008)
        #expect(WindowSwitcher.entries(listed: [listed(10)], windows: [palette], own: own).entries.isEmpty)
    }

    @Test("Own overlays, other layers and transparent surfaces do not delay opening")
    func unrelatedSurfaces() {
        #expect(budget([listed(10), listed(20, pid: own), listed(21, pid: 3, layer: 2),
                        listed(22, pid: 4, alpha: 0)], [1: [window(10)]]) == 0.008)
    }

    @Test("Maintenance still waits for a fresh reply")
    func maintenanceFreshness() {
        #expect(budget([listed(10)], [1: [window(10)]], fresh: true) == 0.08)
        #expect(budget([listed(10)], [:], fresh: true) == 0.5)
    }

    @Test("A caller's tighter bound is preserved")
    func tighterBudget() {
        #expect(budget([listed(10)], [1: [window(10)]], patience: 0.003) == 0.003)
    }

    @Test("Explicit unbounded reads retain their meaning")
    func unboundedRead() {
        #expect(budget([listed(10)], [1: [window(10)]], patience: nil) == nil)
        #expect(budget([listed(10)], [:], patience: nil) == nil)
    }

    @Test("Current WindowServer order and geometry win over cached metadata")
    func movedAndClosedWindows() throws {
        let cache = [window(10), window(20), window(30)]
        let moved = CGRect(x: 1800, y: 30, width: 600, height: 900)
        let current = [listed(20, bounds: moved), listed(10)]
        #expect(budget(current, [1: cache]) == 0.008)
        let entries = WindowSwitcher.entries(listed: current, windows: cache, own: own).entries
        #expect(entries.map { $0.window.id } == [20, 10])
        #expect(entries.first?.bounds == moved)
        #expect(!entries.contains { $0.window.id == 30 })
    }

    @Test("An unanswered owner with no visible or hidden window does not delay known windows")
    func unrelatedUnansweredOwner() {
        #expect(budget([listed(10)], [1: [window(10)]], pids: [1, 2]) == 0.008)
    }

    @Test("An undiscovered freshly launched owner retains its first discovery budget")
    func newlyLaunchedOwner() {
        #expect(budget([listed(10)], [1: [window(10)]], pids: [1, 2], recent: [2]) == 0.08)
        #expect(budget([listed(10)], [1: [window(10)], 2: []], pids: [1, 2], recent: [2]) == 0.008)
    }

    @Test("Recoverable windows absent from the current census still refresh before opening")
    func awayWindowsStillWait() {
        var minimized = window(20)
        minimized.isMinimized = true
        #expect(budget([listed(10)], [1: [window(10), minimized]]) == 0.08)
        #expect(budget([listed(10)], [1: [window(10)], 2: [window(20, pid: 2)]], pids: [1, 2], hidden: [2]) == 0.08)
        var unnumbered = window(nil)
        unnumbered.isMinimized = true
        #expect(budget([listed(10)], [1: [window(10), unnumbered]]) == 0.08)
        #expect(budget([listed(20)], [1: [minimized]]) == 0.008)
    }

    @Test("A reused window ID can only join the current owner's handle")
    func entriesRejectReusedID() {
        let old = window(10, pid: 1)
        let current = window(10, pid: 2)
        #expect(WindowSwitcher.entries(listed: [listed(10, pid: 2)], windows: [old], own: own).entries.isEmpty)
        let joined = WindowSwitcher.entries(listed: [listed(10, pid: 2)], windows: [old, current], own: own).entries
        #expect(joined.count == 1)
        #expect(joined.first?.window.pid == 2)
    }

    @Test("Cached selection stays available while the same owner's refresh is blocked")
    func pendingRefreshDoesNotTakeTheLongBudget() {
        let cache = SwitcherWindowCache<pid_t, [WindowSwitcher.Window<String>]>()
        let initial = cache.request(1) { [window(10)] }
        #expect(initial.wait(timeout: .now() + 2) == .success)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let refresh = cache.request(1) {
            entered.signal()
            guard release.wait(timeout: .now() + 2) == .success else { return nil }
            return [window(10), window(11)]
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let remembered = cache.snapshot(keeping: [1])
        #expect(refresh.wait(timeout: .now()) == .timedOut)
        #expect(budget([listed(10)], remembered) == 0.008)
        #expect(WindowSwitcher.entries(listed: [listed(10)], windows: remembered[1] ?? [], own: own).entries.count == 1)
        release.signal()
        #expect(refresh.wait(timeout: .now() + 2) == .success)
        #expect(cache.snapshot(keeping: [1])[1]?.count == 2)
    }
}
