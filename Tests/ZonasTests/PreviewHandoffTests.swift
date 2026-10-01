import CoreGraphics
import Testing
@testable import Zonas

@Suite("Window previews change their picture and geometry together")
struct PreviewHandoffTests {
    private let a = CGRect(x: 100, y: 80, width: 900, height: 600)
    private let b = CGRect(x: 1200, y: 120, width: 1400, height: 900)
    private let c = CGRect(x: -1600, y: 40, width: 1200, height: 800)

    @Test("A remains intact while B has no frame; B replaces picture and rectangle together")
    func waitingKeepsTheWholePreviousPresentation() {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)

        let waiting = handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        #expect(waiting?.window == 1)
        #expect(waiting?.bounds == a)
        #expect(waiting?.picture == "A")
        #expect(handoff.pendingToken != nil)

        let ready = handoff.choose(window: 2, bounds: b, picture: "B", expectsPicture: true)
        #expect(ready?.window == 2)
        #expect(ready?.bounds == b)
        #expect(ready?.picture == "B")
        #expect(handoff.pendingToken == nil)
    }

    @Test("The first selection waits without exposing an empty preview hole")
    func firstSelectionWaitsForItsPicture() {
        var handoff = PreviewHandoff<String>()
        #expect(handoff.choose(window: 1, bounds: a, picture: nil, expectsPicture: true) == nil)
        #expect(handoff.displayed == nil)
        #expect(handoff.pendingToken != nil)

        let ready = handoff.choose(window: 1, bounds: a, picture: "first", expectsPicture: true)
        #expect(ready?.bounds == a)
        #expect(ready?.picture == "first")
    }

    @Test("Repeated requests for the same pending window preserve its deadline token")
    func repeatedPendingChoiceDoesNotExtendTheDeadline() {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = handoff.pendingToken
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        #expect(handoff.pendingToken == token)
    }

    @Test("A to B to C ignores B's expired deadline and waits for C")
    func rapidSelectionIgnoresAnOldTimeout() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let oldToken = try #require(handoff.pendingToken)
        handoff.choose(window: 3, bounds: c, picture: nil, expectsPicture: true)
        let currentToken = try #require(handoff.pendingToken)
        #expect(currentToken != oldToken)

        let unaffected = handoff.fail(oldToken)
        #expect(unaffected?.window == 1)
        #expect(unaffected?.bounds == a)
        #expect(unaffected?.picture == "A")
        #expect(handoff.pendingToken == currentToken)

        let ready = handoff.choose(window: 3, bounds: c, picture: "C", expectsPicture: true)
        #expect(ready?.window == 3)
        #expect(ready?.bounds == c)
        #expect(ready?.picture == "C")
        #expect(handoff.pendingToken == nil)
    }

    @Test("Returning to a previously selected ID does not revive its earlier timeout")
    func revisitingAWindowGetsANewToken() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let firstB = try #require(handoff.pendingToken)
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let secondB = try #require(handoff.pendingToken)
        #expect(secondB != firstB)
        #expect(handoff.fail(firstB)?.window == 1)
        #expect(handoff.pendingToken == secondB)
    }

    @Test("A timeout presents the pending window's ring, then a late valid frame can fill it")
    func aFailureHasABoundedFallback() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = try #require(handoff.pendingToken)
        let fallback = handoff.fail(token)
        #expect(fallback?.window == 2)
        #expect(fallback?.bounds == b)
        #expect(fallback?.picture == nil)
        #expect(handoff.pendingToken == nil)

        let ready = handoff.choose(window: 2, bounds: b, picture: "late B", expectsPicture: true)
        #expect(ready?.window == 2)
        #expect(ready?.bounds == b)
        #expect(ready?.picture == "late B")
    }

    @Test("A completed frame invalidates its pending timeout")
    func timeoutCannotEraseACompletedFrame() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = try #require(handoff.pendingToken)
        handoff.choose(window: 2, bounds: b, picture: "B", expectsPicture: true)
        #expect(handoff.fail(token)?.picture == "B")
        #expect(handoff.displayed?.bounds == b)
        #expect(handoff.pendingToken == nil)
    }

    @Test("Changing the same window's geometry invalidates the previous pending deadline")
    func resizingChangesThePendingToken() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let oldToken = try #require(handoff.pendingToken)
        let moved = b.offsetBy(dx: 300, dy: -50)
        handoff.choose(window: 2, bounds: moved, picture: nil, expectsPicture: true)
        let newToken = try #require(handoff.pendingToken)
        #expect(oldToken != newToken)
        #expect(handoff.fail(oldToken) == nil)
        #expect(handoff.fail(newToken)?.bounds == moved)
    }

    @Test("Closing the switcher discards both displayed and pending presentations")
    func resetRejectsTheOldTimeout() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = try #require(handoff.pendingToken)
        handoff.reset()
        #expect(handoff.displayed == nil)
        #expect(handoff.pendingToken == nil)
        #expect(handoff.fail(token) == nil)
        #expect(handoff.choose(window: 3, bounds: c, picture: nil, expectsPicture: true) == nil)
    }

    @Test("Selecting a minimized window clears the old preview and its pending deadline")
    func noBoundsClearsThePresentation() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = try #require(handoff.pendingToken)
        #expect(handoff.choose(window: 3, bounds: nil, picture: nil, expectsPicture: true) == nil)
        #expect(handoff.displayed == nil)
        #expect(handoff.pendingToken == nil)
        #expect(handoff.fail(token) == nil)
    }

    @Test("Turning the preview off presents the current ring immediately")
    func disabledPreviewDoesNotWaitForAPicture() throws {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: true)
        let token = try #require(handoff.pendingToken)
        let ring = handoff.choose(window: 2, bounds: b, picture: nil, expectsPicture: false)
        #expect(ring?.window == 2)
        #expect(ring?.bounds == b)
        #expect(ring?.picture == nil)
        #expect(handoff.pendingToken == nil)
        #expect(handoff.fail(token)?.bounds == b)
    }

    @Test("A window without a capture ID still gets its ring immediately")
    func noCaptureIDDoesNotStartAnImpossibleWait() {
        var handoff = PreviewHandoff<String>()
        let ring = handoff.choose(window: nil, bounds: a, picture: nil, expectsPicture: true)
        #expect(ring?.bounds == a)
        #expect(ring?.window == nil)
        #expect(handoff.pendingToken == nil)
    }

    @Test("A cached frame presents the new window immediately")
    func aWarmWindowDoesNotWait() {
        var handoff = PreviewHandoff<String>()
        handoff.choose(window: 1, bounds: a, picture: "A", expectsPicture: true)
        let warm = handoff.choose(window: 2, bounds: b, picture: "cached B", expectsPicture: true)
        #expect(warm?.window == 2)
        #expect(warm?.bounds == b)
        #expect(warm?.picture == "cached B")
        #expect(handoff.pendingToken == nil)
    }
}

@Suite("Native preview frames stay within a bounded LRU cache")
struct PreviewFrameCacheTests {
    @Test("Reading a frame protects it when the count limit evicts another")
    func countEvictionUsesRecentReads() {
        var cache = PreviewFrameCache<String>(byteLimit: 100, countLimit: 2)
        cache.store("A", for: 1, bytes: 10)
        cache.store("B", for: 2, bytes: 10)
        #expect(cache.picture(of: 1) == "A")
        cache.store("C", for: 3, bytes: 10)
        #expect(cache.picture(of: 2) == nil)
        #expect(cache.picture(of: 1) == "A")
        #expect(cache.picture(of: 3) == "C")
        #expect(cache.count == 2)
        #expect(cache.bytes == 20)
    }

    @Test("The memory limit also evicts the least recently used frame")
    func memoryEvictionUsesRecentReads() {
        var cache = PreviewFrameCache<String>(byteLimit: 10, countLimit: 4)
        cache.store("A", for: 1, bytes: 4)
        cache.store("B", for: 2, bytes: 4)
        #expect(cache.picture(of: 1) == "A")
        cache.store("C", for: 3, bytes: 4)
        #expect(cache.picture(of: 2) == nil)
        #expect(cache.picture(of: 1) == "A")
        #expect(cache.picture(of: 3) == "C")
        #expect(cache.bytes == 8)
        #expect(cache.count == 2)
    }

    @Test("Replacing a frame accounts for its new size without double counting")
    func replacementUsesTheNewCost() {
        var cache = PreviewFrameCache<String>(byteLimit: 12, countLimit: 4)
        cache.store("old A", for: 1, bytes: 4)
        cache.store("B", for: 2, bytes: 4)
        cache.store("new A", for: 1, bytes: 8)
        #expect(cache.bytes == 12)
        #expect(cache.count == 2)
        #expect(cache.picture(of: 1) == "new A")
        #expect(cache.picture(of: 2) == "B")
        cache.store("larger A", for: 1, bytes: 9)
        #expect(cache.bytes == 9)
        #expect(cache.count == 1)
        #expect(cache.picture(of: 2) == nil)
        #expect(cache.picture(of: 1) == "larger A")
    }

    @Test("An oversized frame stays presentable, evicts other frames, and is replaced normally")
    func oversizedCurrentFrameIsTheOnlyBudgetException() {
        var cache = PreviewFrameCache<String>(byteLimit: 10, countLimit: 4)
        cache.store("A", for: 1, bytes: 4)
        cache.store("large B", for: 2, bytes: 24)
        #expect(cache.count == 1)
        #expect(cache.bytes == 24)
        #expect(cache.picture(of: 1) == nil)
        #expect(cache.picture(of: 2) == "large B")

        cache.store("C", for: 3, bytes: 6)
        #expect(cache.count == 1)
        #expect(cache.bytes == 6)
        #expect(cache.picture(of: 2) == nil)
        #expect(cache.picture(of: 3) == "C")
    }

    @Test("A frame exactly at the budget fits without evicting it")
    func exactBudgetIsAllowed() {
        var cache = PreviewFrameCache<String>(byteLimit: 10, countLimit: 4)
        cache.store("A", for: 1, bytes: 4)
        cache.store("B", for: 2, bytes: 6)
        #expect(cache.count == 2)
        #expect(cache.bytes == 10)
        #expect(cache.picture(of: 1) == "A")
        #expect(cache.picture(of: 2) == "B")
    }

    @Test("Rejected negative costs leave the previous valid frame and accounting unchanged")
    func invalidCostCannotCorruptAnExistingEntry() {
        var cache = PreviewFrameCache<String>(byteLimit: 10, countLimit: 4)
        cache.store("A", for: 1, bytes: 4)
        cache.store("invalid", for: 1, bytes: -1)
        #expect(cache.picture(of: 1) == "A")
        #expect(cache.count == 1)
        #expect(cache.bytes == 4)
    }

    @Test("Reset releases every frame and clears accounting before another session")
    func resetLeavesNoFramesOrAccounting() {
        var cache = PreviewFrameCache<String>(byteLimit: 10, countLimit: 4)
        cache.store("large", for: 1, bytes: 24)
        cache.reset()
        #expect(cache.count == 0)
        #expect(cache.bytes == 0)
        #expect(cache.picture(of: 1) == nil)
        cache.store("new", for: 2, bytes: 6)
        #expect(cache.count == 1)
        #expect(cache.bytes == 6)
        #expect(cache.picture(of: 2) == "new")
    }

    @Test("A missing lookup does not change which stored frame is least recent")
    func cacheMissDoesNotAffectEvictionOrder() {
        var cache = PreviewFrameCache<String>(byteLimit: 20, countLimit: 2)
        cache.store("A", for: 1, bytes: 4)
        cache.store("B", for: 2, bytes: 4)
        #expect(cache.picture(of: 99) == nil)
        cache.store("C", for: 3, bytes: 4)
        #expect(cache.picture(of: 1) == nil)
        #expect(cache.picture(of: 2) == "B")
        #expect(cache.picture(of: 3) == "C")
    }
}
