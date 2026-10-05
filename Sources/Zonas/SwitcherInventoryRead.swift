import Foundation

/// A slow application must not set the opening time for already known windows.
/// WindowServer still supplies current order and geometry on every gesture;
/// cached AX handles are only a fallback while their refresh runs elsewhere.
enum SwitcherInventoryRead {
    static let warmBudget: TimeInterval = 0.008

    static func budget<Handle>(listed: [WindowSwitcher.Listed],
                               memory: [pid_t: [WindowSwitcher.Window<Handle>]],
                               pids: [pid_t], hidden: Set<pid_t> = [], recent: Set<pid_t> = [], own: pid_t,
                               patience: TimeInterval?, waitingForFresh: Bool) -> TimeInterval? {
        guard let patience else { return nil }
        if memory.isEmpty { return max(patience, 0.5) }
        guard !waitingForFresh else { return patience }
        // A hidden owner can contribute windows outside the on-screen census.
        // A newly launched owner may already have a minimized window, so its
        // first discovery retains the normal budget too.
        // An unknown old owner with nothing visible must not hold up every known
        // window indefinitely; its read continues in the background instead.
        guard pids.filter({ $0 != own && (hidden.contains($0) || recent.contains($0)) }).allSatisfy({ memory[$0] != nil }) else { return patience }
        let visible = listed.filter { $0.layer == 0 && $0.alpha > 0 && $0.pid != own }
        guard visible.allSatisfy({ listed in
            memory[listed.pid]?.contains(where: { $0.id == listed.id && $0.pid == listed.pid }) == true
        }) else { return patience }
        let visibleIDs = Set(visible.map(\.id))
        let away = memory.values.joined().contains { window in
            WindowSwitcher.isSwitchable(subrole: window.subrole, title: window.title)
                && (window.isMinimized || hidden.contains(window.pid))
                && window.id.map({ !visibleIDs.contains($0) }) != false
        }
        // A minimized/hidden window can close without an on-screen change.
        // Preserve the discovery budget rather than creating a new cache-only
        // path that resurrects those absent windows after idle.
        return away ? patience : min(patience, warmBudget)
    }
}
