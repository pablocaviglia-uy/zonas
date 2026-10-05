import Dispatch

/// Keys are recorded while other applications answer in the background. A
/// release ends one gesture; a second tap must not turn it into a two-step
/// selection merely because the first application's reply was slow.
struct SwitcherOpening {
    struct Gesture {
        let backwards: Bool
        let began: DispatchTime
        private(set) var delta = 0
        private(set) var presses = 1
        private(set) var lastDirection = 1
        fileprivate(set) var released = false

        fileprivate mutating func step(backwards: Bool) {
            lastDirection = backwards ? -1 : 1
            delta += lastDirection
            presses += 1
        }

        func cycle(count: Int) -> WindowSwitcher.Cycle? {
            guard var cycle = WindowSwitcher.Cycle(count: count, backwards: backwards) else { return nil }
            cycle.step(delta)
            return cycle
        }
    }

    private(set) var gestures: [Gesture] = []

    mutating func press(backwards: Bool, at time: DispatchTime = .now()) {
        if let last = gestures.indices.last, !gestures[last].released {
            gestures[last].step(backwards: backwards)
        } else {
            gestures.append(Gesture(backwards: backwards, began: time, lastDirection: backwards ? -1 : 1))
        }
    }

    mutating func release() {
        guard let last = gestures.indices.last else { return }
        gestures[last].released = true
    }
}
