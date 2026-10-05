import Foundation

/// One outstanding AX read per process, shared by launch warm-up and opening
/// requests. A read that joins warm-up must wait for that same request rather
/// than see an empty local group and conclude there are no windows.
final class SwitcherWindowCache<Key: Hashable, Value> {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private var requests: [Key: DispatchGroup] = [:]

    func request(_ key: Key, read: @escaping () -> Value?) -> DispatchGroup {
        lock.lock()
        if let existing = requests[key] {
            lock.unlock()
            return existing
        }
        let completion = DispatchGroup()
        completion.enter()
        requests[key] = completion
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = read()
            self.lock.lock()
            if let value { self.values[key] = value }
            self.requests.removeValue(forKey: key)
            self.lock.unlock()
            completion.leave()
        }
        return completion
    }

    func snapshot(keeping keys: Set<Key>) -> [Key: Value] {
        lock.lock()
        defer { lock.unlock() }
        values = values.filter { keys.contains($0.key) }
        return values
    }
}
