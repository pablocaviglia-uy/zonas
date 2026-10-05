import CoreGraphics
import Foundation
import Testing
@testable import Zonas

@Suite("An unstarted preview stream is consumed only for its exact current census entry")
struct PreviewStandbyTests {
    private let identity = PreviewStandbyIdentity(window: 42, owner: 100,
                                                  bounds: CGRect(x: 100, y: 50, width: 1200, height: 900))

    @Test("One exact fresh match can be consumed once, never returned to the idle slot")
    func aPreparedStreamIsSingleConsumption() {
        var cache = PreviewStandbyCache<String>()
        cache.store("unstarted", identity: identity, preparedAt: 10)
        let taken = cache.take(matching: identity, now: 11, maximumAge: 30)
        #expect(taken?.matches == true)
        #expect(taken?.value == "unstarted")
        #expect(cache.count == 0)
        #expect(cache.take(matching: identity, now: 12, maximumAge: 30) == nil)
    }

    @Test("A reused window number cannot adopt another owner's prepared filter")
    func anotherProcessCannotAdoptTheStream() {
        var cache = PreviewStandbyCache<String>()
        cache.store("old owner", identity: identity, preparedAt: 10)
        let other = PreviewStandbyIdentity(window: identity.window, owner: 200, bounds: identity.bounds)
        let taken = cache.take(matching: other, now: 11, maximumAge: 30)
        #expect(taken?.matches == false)
        #expect(taken?.value == "old owner")
        #expect(cache.count == 0)
        #expect(cache.take(matching: identity, now: 11, maximumAge: 30) == nil)
    }

    @Test("A different window cannot adopt the prepared stream even with identical geometry and owner")
    func anotherWindowCannotAdoptTheStream() {
        var cache = PreviewStandbyCache<String>()
        cache.store("original", identity: identity, preparedAt: 10)
        let other = PreviewStandbyIdentity(window: 43, owner: identity.owner, bounds: identity.bounds)
        #expect(cache.take(matching: other, now: 11, maximumAge: 30)?.matches == false)
        #expect(cache.count == 0)
    }

    @Test("Moving between displays invalidates preparation even when the point size is unchanged")
    func aMovedWindowCannotAdoptItsPreviousScale() {
        var cache = PreviewStandbyCache<String>()
        cache.store("previous display", identity: identity, preparedAt: 10)
        let moved = PreviewStandbyIdentity(window: identity.window, owner: identity.owner,
                                           bounds: identity.bounds.offsetBy(dx: 3000, dy: 0))
        #expect(moved.bounds.size == identity.bounds.size)
        #expect(cache.take(matching: moved, now: 11, maximumAge: 30)?.matches == false)
        #expect(cache.count == 0)
    }

    @Test("A resized window cannot adopt a buffer configured at its previous native size")
    func aResizedWindowCannotAdoptTheStream() {
        var cache = PreviewStandbyCache<String>()
        cache.store("previous size", identity: identity, preparedAt: 10)
        let resized = PreviewStandbyIdentity(window: identity.window, owner: identity.owner,
                                             bounds: CGRect(x: 100, y: 50, width: 1600, height: 900))
        #expect(cache.take(matching: resized, now: 11, maximumAge: 30)?.matches == false)
    }

    @Test("Checking readiness cannot renew the thirty-second preparation lifetime")
    func readinessChecksDoNotKeepAnOldStreamAlive() {
        var cache = PreviewStandbyCache<String>()
        cache.store("prepared", identity: identity, preparedAt: 10)
        #expect(cache.contains(identity, now: 20, maximumAge: 30))
        #expect(cache.contains(identity, now: 40, maximumAge: 30))
        #expect(!cache.contains(identity, now: 40.001, maximumAge: 30))
        #expect(cache.take(matching: identity, now: 40.001, maximumAge: 30)?.matches == false)
        #expect(cache.count == 0)
    }

    @Test("An aging ready stream stays consumable while maintenance decides to build its replacement")
    func renewalInspectionDoesNotRemoveOrRenewTheReadyStream() {
        var cache = PreviewStandbyCache<String>()
        cache.store("ready during replacement", identity: identity, preparedAt: 10)
        #expect(cache.age(of: identity, now: 25) == 15)
        #expect(cache.age(of: identity, now: 30) == 20)
        #expect(cache.count == 1)
        let taken = cache.take(matching: identity, now: 39, maximumAge: 30)
        #expect(taken?.matches == true)
        #expect(taken?.value == "ready during replacement")
        #expect(cache.count == 0)
    }

    @Test("Replacing a candidate returns the old resource for invalidation and retains only one")
    func replacementIsBoundedAndReleasesTheOldValue() {
        var cache = PreviewStandbyCache<String>()
        #expect(cache.store("old", identity: identity, preparedAt: 10) == nil)
        let next = PreviewStandbyIdentity(window: 43, owner: identity.owner, bounds: identity.bounds)
        #expect(cache.store("next", identity: next, preparedAt: 11) == "old")
        #expect(cache.count == 1)
        #expect(!cache.contains(identity, now: 12, maximumAge: 30))
        let taken = cache.take(matching: next, now: 12, maximumAge: 30)
        #expect(taken?.matches == true)
        #expect(taken?.value == "next")
        #expect(cache.count == 0)
    }

    @Test("Disable, wake and display invalidation can release the resource without consuming it")
    func invalidationRemovesTheReadyResource() {
        var cache = PreviewStandbyCache<String>()
        cache.store("prepared", identity: identity, preparedAt: 10)
        #expect(cache.remove() == "prepared")
        #expect(cache.count == 0)
        #expect(cache.remove() == nil)
        #expect(cache.take(matching: identity, now: 11, maximumAge: 30) == nil)
    }

    @Test("Future or non-finite ages never permit adopting a prepared resource")
    func invalidAgesRejectAndConsumeTheEntry() {
        for now in [9, Double.nan, Double.infinity, -Double.infinity] {
            var cache = PreviewStandbyCache<String>()
            cache.store("prepared", identity: identity, preparedAt: 10)
            #expect(cache.take(matching: identity, now: now, maximumAge: 30)?.matches == false)
            #expect(cache.count == 0)
        }
        for maximumAge in [-1, Double.nan, Double.infinity] {
            var cache = PreviewStandbyCache<String>()
            cache.store("prepared", identity: identity, preparedAt: 10)
            #expect(cache.take(matching: identity, now: 11, maximumAge: maximumAge)?.matches == false)
        }
    }

    @Test("Invalid IDs, owners and geometry cannot describe a capture candidate")
    func invalidCensusEntriesAreRejected() {
        let invalid = [
            PreviewStandbyIdentity(window: 0, owner: identity.owner, bounds: identity.bounds),
            PreviewStandbyIdentity(window: identity.window, owner: 0, bounds: identity.bounds),
            PreviewStandbyIdentity(window: identity.window, owner: identity.owner, bounds: .zero),
            PreviewStandbyIdentity(window: identity.window, owner: identity.owner,
                                    bounds: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)),
            PreviewStandbyIdentity(window: identity.window, owner: identity.owner,
                                    bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)),
        ]
        for candidate in invalid { #expect(!candidate.isValid) }
        #expect(identity.isValid)
    }
}
