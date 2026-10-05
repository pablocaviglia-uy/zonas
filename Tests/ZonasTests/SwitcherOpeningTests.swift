import Dispatch
import Testing
@testable import Zonas

@Suite("Switcher keys retain their gesture while the inventory is being read")
struct SwitcherOpeningTests {
    private func at(_ nanoseconds: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: nanoseconds)
    }

    @Test("Opening forward retains the usual previous-window selection")
    func firstForwardPress() throws {
        var opening = SwitcherOpening()
        opening.press(backwards: false, at: at(1_000))
        let gesture = try #require(opening.gestures.first)
        #expect(opening.gestures.count == 1)
        #expect(!gesture.backwards)
        #expect(!gesture.released)
        #expect(gesture.presses == 1)
        #expect(gesture.delta == 0)
        #expect(gesture.began.uptimeNanoseconds == 1_000)
        #expect(gesture.cycle(count: 5)?.index == 1)
    }

    @Test("Repeated forward keys during a read are counted in the held gesture")
    func repeatedForwardKeys() throws {
        var opening = SwitcherOpening()
        for time in [1_000, 2_000, 3_000] as [UInt64] {
            opening.press(backwards: false, at: at(time))
        }
        let gesture = try #require(opening.gestures.first)
        #expect(opening.gestures.count == 1)
        #expect(gesture.presses == 3)
        #expect(gesture.delta == 2)
        #expect(gesture.cycle(count: 5)?.index == 3)
        #expect(gesture.began.uptimeNanoseconds == 1_000)
    }

    @Test("Repeated backward keys begin at the far end and continue backward")
    func repeatedBackwardKeys() throws {
        var opening = SwitcherOpening()
        for time in [1_000, 2_000, 3_000] as [UInt64] {
            opening.press(backwards: true, at: at(time))
        }
        let gesture = try #require(opening.gestures.first)
        #expect(gesture.backwards)
        #expect(gesture.presses == 3)
        #expect(gesture.delta == -2)
        #expect(gesture.cycle(count: 5)?.index == 2)
    }

    @Test("Changing direction during the read moves the same choice")
    func mixedDirections() throws {
        var opening = SwitcherOpening()
        opening.press(backwards: false)
        opening.press(backwards: true)
        opening.press(backwards: false)
        let gesture = try #require(opening.gestures.first)
        #expect(opening.gestures.count == 1)
        #expect(!gesture.backwards)
        #expect(gesture.presses == 3)
        #expect(gesture.delta == 0)
        #expect(gesture.cycle(count: 4)?.index == 1)
    }

    @Test("Queued steps wrap in both directions")
    func wrapping() throws {
        for backwards in [false, true] {
            var opening = SwitcherOpening()
            for _ in 0..<7 { opening.press(backwards: backwards) }
            let gesture = try #require(opening.gestures.first)
            #expect(gesture.presses == 7)
            #expect(gesture.cycle(count: 3)?.index == (backwards ? 2 : 1))
        }
    }

    @Test("A release before inventory readiness marks the choice for commit")
    func releasedBeforeReadFinishes() throws {
        var opening = SwitcherOpening()
        opening.press(backwards: false, at: at(1_000))
        opening.press(backwards: false, at: at(2_000))
        opening.release()
        let gesture = try #require(opening.gestures.first)
        #expect(gesture.released)
        #expect(gesture.presses == 2)
        #expect(gesture.cycle(count: 4)?.index == 2)
    }

    @Test("Two rapid released taps toggle back instead of selecting a third window")
    func releasedTapsRemainDistinct() throws {
        var opening = SwitcherOpening()
        opening.press(backwards: false, at: at(1_000))
        opening.release()
        opening.press(backwards: false, at: at(2_000))
        opening.release()
        #expect(opening.gestures.count == 2)
        #expect(opening.gestures.allSatisfy { $0.released && $0.presses == 1 && $0.delta == 0 })

        // Completed activations become the most recent window, as they would
        // if the inventory had arrived before either tap was pressed.
        var order = ["front", "previous", "third"]
        var choices: [String] = []
        for gesture in opening.gestures {
            let cycle = try #require(gesture.cycle(count: order.count))
            let chosen = order.remove(at: cycle.index)
            choices.append(chosen)
            order.insert(chosen, at: 0)
        }
        #expect(choices == ["previous", "front"])
        #expect(order == ["front", "previous", "third"])
    }

    @Test("A tap followed by a held gesture retains the second gesture's own time and keys")
    func latestGestureHasOwnStartAndCount() throws {
        var opening = SwitcherOpening()
        opening.press(backwards: false, at: at(1_000))
        opening.release()
        opening.press(backwards: true, at: at(2_000))
        opening.press(backwards: false, at: at(3_000))
        opening.press(backwards: true, at: at(4_000))
        let first = try #require(opening.gestures.first)
        let latest = try #require(opening.gestures.last)
        #expect(opening.gestures.count == 2)
        #expect(first.began.uptimeNanoseconds == 1_000)
        #expect(first.presses == 1)
        #expect(first.released)
        #expect(latest.began.uptimeNanoseconds == 2_000)
        #expect(latest.presses == 3)
        #expect(latest.backwards)
        #expect(!latest.released)
        #expect(latest.delta == 0)
        #expect(latest.cycle(count: 4)?.index == 3)
    }

    @Test("Repeated release polls cannot create a phantom gesture")
    func releaseIsIdempotent() throws {
        var opening = SwitcherOpening()
        opening.release()
        opening.release()
        #expect(opening.gestures.isEmpty)
        opening.press(backwards: false)
        opening.release()
        opening.release()
        let gesture = try #require(opening.gestures.first)
        #expect(opening.gestures.count == 1)
        #expect(gesture.released)
        #expect(gesture.presses == 1)
    }

    @Test("A single-window inventory always resolves to its only entry")
    func singleWindow() throws {
        var opening = SwitcherOpening()
        for backwards in [false, true, true, false, false] { opening.press(backwards: backwards) }
        let gesture = try #require(opening.gestures.first)
        #expect(gesture.cycle(count: 1)?.index == 0)
    }

    @Test("An empty inventory has no selection even after queued keys or releases")
    func emptyInventory() {
        var opening = SwitcherOpening()
        opening.press(backwards: false)
        opening.press(backwards: true)
        opening.release()
        opening.press(backwards: true)
        opening.release()
        #expect(opening.gestures.count == 2)
        #expect(opening.gestures.allSatisfy { $0.cycle(count: 0) == nil })
    }
}
