import CoreGraphics
import Foundation
import Testing
@testable import Zonas

@Suite("Recent native frames are reused only for the same window and geometry")
struct PreviewCaptureCacheTests {
    private let identity = PreviewFrameIdentity(owner: 100, size: CGSize(width: 1200, height: 900))

    @Test("A recent frame survives another session's census and stays available immediately")
    func aRecentFrameSurvivesPruning() {
        var cache = PreviewFrameCache<String>(byteLimit: 100, countLimit: 4)
        cache.store("recent", for: 1, bytes: 40, identity: identity, capturedAt: 10)
        cache.prune(windows: [1, 2], identities: [1: identity], now: 11, maximumAge: 2)
        #expect(cache.picture(of: 1, matching: identity, now: 11, maximumAge: 2) == "recent")
        #expect(cache.bytes == 40)
    }

    @Test("Reading a frame does not renew its capture age")
    func readsCannotKeepAnOldFrameAlive() {
        var cache = PreviewFrameCache<String>()
        cache.store("recent", for: 1, bytes: 40, identity: identity, capturedAt: 10)
        #expect(cache.picture(of: 1, matching: identity, now: 11, maximumAge: 2) == "recent")
        #expect(cache.picture(of: 1, matching: identity, now: 12, maximumAge: 2) == "recent")
        #expect(cache.picture(of: 1, matching: identity, now: 12.001, maximumAge: 2) == nil)
        #expect(cache.count == 0)
        #expect(cache.bytes == 0)
    }

    @Test("A reused window number cannot display another process's frame")
    func changedOwnershipRejectsTheOldPicture() {
        var cache = PreviewFrameCache<String>()
        cache.store("old process", for: 1, bytes: 40, identity: identity, capturedAt: 10)
        let other = PreviewFrameIdentity(owner: 200, size: identity.size)
        #expect(cache.picture(of: 1, matching: other, now: 11, maximumAge: 2) == nil)
        #expect(cache.count == 0)
        #expect(cache.bytes == 0)
    }

    @Test("A resized window cannot reuse a stretched native frame")
    func resizedWindowRejectsTheOldPicture() {
        var cache = PreviewFrameCache<String>()
        cache.store("old size", for: 1, bytes: 40, identity: identity, capturedAt: 10)
        let resized = PreviewFrameIdentity(owner: identity.owner, size: CGSize(width: 1600, height: 900))
        #expect(cache.picture(of: 1, matching: resized, now: 11, maximumAge: 2) == nil)
        #expect(cache.count == 0)
    }

    @Test("Pruning releases closed, expired, changed and unvalidated windows together")
    func censusPruningIsSelectiveAndAccountsForBytes() {
        var cache = PreviewFrameCache<String>(byteLimit: 100, countLimit: 8)
        for id in CGWindowID(1)...CGWindowID(5) {
            cache.store("frame", for: id, bytes: 10, identity: identity, capturedAt: id == 3 ? 5 : 10)
        }
        let resized = PreviewFrameIdentity(owner: identity.owner, size: CGSize(width: 800, height: 900))
        cache.prune(windows: [1, 3, 4, 5], identities: [1: identity, 3: identity, 4: resized], now: 11, maximumAge: 2)
        #expect(cache.count == 1)
        #expect(cache.bytes == 10)
        #expect(cache.picture(of: 1) == "frame")
        for id in CGWindowID(2)...CGWindowID(5) { #expect(cache.picture(of: id) == nil) }
    }

    @Test("Invalid or future ages cannot expose a frame")
    func invalidAgesAreRejected() {
        for now in [Double.nan, Double.infinity, -Double.infinity, 9] {
            var cache = PreviewFrameCache<String>()
            cache.store("frame", for: 1, bytes: 40, identity: identity, capturedAt: 10)
            #expect(cache.picture(of: 1, matching: identity, now: now, maximumAge: 2) == nil)
            #expect(cache.bytes == 0)
        }
    }

    @Test("Fresh native replacements renew the capture age without growing the cache")
    func liveFramesReplaceAndRenewTheEntry() {
        var cache = PreviewFrameCache<String>()
        cache.store("still", for: 1, bytes: 40, identity: identity, capturedAt: 10)
        cache.store("live", for: 1, bytes: 60, identity: identity, capturedAt: 11.5)
        #expect(cache.picture(of: 1, matching: identity, now: 13, maximumAge: 2) == "live")
        #expect(cache.count == 1)
        #expect(cache.bytes == 60)
    }
}

@Suite("A still capture completion cannot cross a switcher session")
struct PreviewCaptureTicketTests {
    private let identity = PreviewFrameIdentity(owner: 100, size: CGSize(width: 1200, height: 900))

    @Test("The original request can complete while its window still belongs to this session")
    func theCurrentCaptureIsAccepted() {
        let session = UUID(), request = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: request, window: 1, owner: identity.owner, identity: identity)
        #expect(ticket.isCurrent(session: session, request: request, windows: [1], owners: [1: identity.owner], identities: [1: identity]))
    }

    @Test("Closing cancels the lease even if an already submitted capture finishes later")
    func closingRejectsCompletion() {
        let session = UUID(), request = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: request, window: 1, owner: identity.owner, identity: identity)
        #expect(!ticket.isCurrent(session: UUID(), request: nil, windows: [], owners: [:], identities: [:]))
    }

    @Test("Reopening on the same window and size does not revive the previous capture")
    func reopeningRejectsAnOldSession() {
        let request = UUID()
        let ticket = PreviewCaptureTicket(session: UUID(), request: request, window: 1, owner: identity.owner, identity: identity)
        #expect(!ticket.isCurrent(session: UUID(), request: request, windows: [1], owners: [1: identity.owner], identities: [1: identity]))
    }

    @Test("A superseded request for the same window cannot remove or replace its successor")
    func replacedRequestRejectsCompletion() {
        let session = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: UUID(), window: 1, owner: identity.owner, identity: identity)
        #expect(!ticket.isCurrent(session: session, request: UUID(), windows: [1], owners: [1: identity.owner], identities: [1: identity]))
    }

    @Test("Closing, resizing or reusing the window number invalidates an otherwise current request")
    func changedWindowRejectsCompletion() {
        let session = UUID(), request = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: request, window: 1, owner: identity.owner, identity: identity)
        #expect(!ticket.isCurrent(session: session, request: request, windows: [], owners: [:], identities: [1: identity]))
        for replacement in [PreviewFrameIdentity(owner: 200, size: identity.size),
                            PreviewFrameIdentity(owner: identity.owner, size: CGSize(width: 800, height: 900))] {
            #expect(!ticket.isCurrent(session: session, request: request, windows: [1], owners: [1: identity.owner], identities: [1: replacement]))
        }
    }

    @Test("A minimized thumbnail request still rejects a window number reused by another owner")
    func unknownGeometryStillRequiresTheSameOwner() {
        let session = UUID(), request = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: request, window: 1,
                                          owner: identity.owner, identity: nil)
        #expect(!ticket.isCurrent(session: session, request: request, windows: [1], owners: [1: 200], identities: [:]))
        #expect(!ticket.isCurrent(session: session, request: request, windows: [1], owners: [:], identities: [:]))
    }

    @Test("An unminimized identity cannot accept an old minimized-window thumbnail request")
    func newlyKnownGeometryRejectsAnUnvalidatedCapture() {
        let session = UUID(), request = UUID()
        let ticket = PreviewCaptureTicket(session: session, request: request, window: 1, owner: identity.owner, identity: nil)
        #expect(!ticket.isCurrent(session: session, request: request, windows: [1], owners: [1: identity.owner], identities: [1: identity]))
        #expect(ticket.isCurrent(session: session, request: request, windows: [1], owners: [1: identity.owner], identities: [:]))
    }
}

@Suite("Live frame delivery retains only the newest pending image")
struct PreviewLatestFrameTests {
    @Test("An occupied main thread receives the newest frame with one scheduled delivery")
    func pendingDeliveryCoalescesEveryIntermediateFrame() {
        let frames = PreviewLatestFrame<Int>()
        var schedules = 0
        for value in 0..<1000 { if frames.offer(value) { schedules += 1 } }
        #expect(schedules == 1)
        #expect(frames.take() == 999)
        #expect(frames.take() == nil)
        #expect(frames.offer(1000))
        #expect(frames.take() == 1000)
    }

    @Test("Invalidating the stream cancels a pending delivery and rejects every later frame")
    func invalidationCancelsThePendingImage() {
        let frames = PreviewLatestFrame<Int>()
        #expect(frames.offer(1))
        frames.invalidate()
        #expect(!frames.isActive)
        #expect(frames.take() == nil)
        #expect(!frames.offer(2))
        #expect(frames.take() == nil)
    }

    @Test("Replacing or cancelling a queued frame releases its large image immediately")
    func intermediateImagesAreNotRetained() {
        final class Frame {}
        let frames = PreviewLatestFrame<Frame>()
        weak var first: Frame?
        weak var latest: Frame?
        do {
            let value = Frame()
            first = value
            #expect(frames.offer(value))
        }
        #expect(first != nil)
        do {
            let value = Frame()
            latest = value
            #expect(!frames.offer(value))
        }
        #expect(first == nil)
        #expect(latest != nil)
        frames.invalidate()
        #expect(latest == nil)
    }
}

@Suite("Native screenshot work stays bounded during fast switching")
struct PreviewNativeWorkQueueTests {
    @Test("Repeated cold choices retain only the latest selected and neighbor behind two running captures")
    func rapidChoicesCoalescePendingWork() {
        var queue = PreviewNativeWorkQueue()
        let first = UUID(), neighbor = UUID()
        #expect(queue.enqueue(first, selected: true).isEmpty)
        #expect(queue.takeNext() == first)
        #expect(queue.enqueue(neighbor, selected: false).isEmpty)
        #expect(queue.takeNext() == neighbor)
        #expect(queue.running.count == 2)
        let b = UUID(), c = UUID(), next = UUID(), lastNext = UUID()
        _ = queue.enqueue(b, selected: true)
        #expect(queue.enqueue(c, selected: true) == [b])
        _ = queue.enqueue(next, selected: false)
        #expect(queue.enqueue(lastNext, selected: false) == [next])
        #expect(queue.takeNext() == nil)
        queue.finish(first)
        #expect(queue.takeNext() == c)
        #expect(queue.running.count == 2)
        queue.finish(neighbor)
        #expect(queue.takeNext() == lastNext)
        #expect(queue.running.count == 2)
    }

    @Test("Selected work has priority when the next compositor slot opens")
    func selectedStartsBeforeThePendingNeighbor() {
        var queue = PreviewNativeWorkQueue()
        let neighbor = UUID(), selected = UUID()
        _ = queue.enqueue(neighbor, selected: false)
        _ = queue.enqueue(selected, selected: true)
        #expect(queue.takeNext() == selected)
        #expect(queue.takeNext() == neighbor)
    }

    @Test("Closing clears pending work without forgetting already submitted captures")
    func closingCannotMakeSubmittedWorkExceedTheLimit() {
        var queue = PreviewNativeWorkQueue()
        let first = UUID(), second = UUID(), obsolete = UUID(), reopened = UUID()
        _ = queue.enqueue(first, selected: true); _ = queue.takeNext()
        _ = queue.enqueue(second, selected: false); _ = queue.takeNext()
        _ = queue.enqueue(obsolete, selected: true)
        queue.cancelPending()
        _ = queue.enqueue(reopened, selected: true)
        #expect(queue.running.count == 2)
        #expect(queue.takeNext() == nil)
        queue.finish(first)
        #expect(queue.takeNext() == reopened)
        #expect(!queue.running.contains(obsolete))
    }

    @Test("An already captured neighbor can be promoted without submitting it twice")
    func selectingTheNeighborPromotesItsExistingWork() {
        var queue = PreviewNativeWorkQueue()
        let neighbor = UUID(), next = UUID()
        _ = queue.enqueue(neighbor, selected: false)
        #expect(queue.takeNext() == neighbor)
        #expect(queue.enqueue(neighbor, selected: true).isEmpty)
        _ = queue.enqueue(next, selected: false)
        #expect(queue.takeNext() == next)
        #expect(queue.running.count == 2)
    }

    @Test("At most one neighbor is submitted while the current selection needs no screenshot")
    func prefetchedNeighborsDoNotOccupyBothSlots() {
        var queue = PreviewNativeWorkQueue()
        let first = UUID(), next = UUID()
        _ = queue.enqueue(first, selected: false)
        #expect(queue.takeNext() == first)
        _ = queue.enqueue(next, selected: false)
        #expect(queue.takeNext() == nil)
        queue.finish(first)
        #expect(queue.takeNext() == next)
    }
}
