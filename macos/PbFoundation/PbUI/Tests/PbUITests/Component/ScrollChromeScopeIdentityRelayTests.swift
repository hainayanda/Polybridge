import AppKit
import PbTestUtilities
@testable import PbUI
import Testing

// MARK: - ScrollChromeScopeIdentityRelayTests

@MainActor @Suite(.serialized) struct ScrollChromeScopeIdentityRelayTests {
    @Test func givenTwoMarkersReportingTheSameScrollView_whenReportsCoalesce_thenIdentityPublishesOnce() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let first = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let second = ScrollChromeScopeMarkerView(pairID: first.pairID)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var delivered: [ObjectIdentifier?] = []
        relay.install { delivered.append($0.map(ObjectIdentifier.init)) }

        // when — both marker halves discover the same native owner in one main-queue burst.
        relay.report(scroll, from: first)
        relay.report(scroll, from: second)
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // then
        #expect(delivered == [ObjectIdentifier(scroll)])
    }

    @Test func givenOneMarkerChurns_whenItsPeerStillOwnsTheScroll_thenIdentitySurvivesUntilBothDetach() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let first = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let second = ScrollChromeScopeMarkerView(pairID: first.pairID)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var delivered: [ObjectIdentifier?] = []
        relay.install { delivered.append($0.map(ObjectIdentifier.init)) }
        relay.report(scroll, from: first)
        relay.report(scroll, from: second)
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // when — one marker is replaced, then the surviving marker is replaced too.
        relay.report(nil, from: first)
        await Task.yield()
        #expect(delivered == [ObjectIdentifier(scroll)])
        relay.report(nil, from: second)
        await waitUntil(timeout: 2) { delivered.count == 2 }

        // then
        #expect(delivered == [ObjectIdentifier(scroll), nil])
    }

    @Test func givenReportsArriveDuringLayout_whenDeferredDeliveryRuns_thenOnlyNewestIdentityPublishesAfterLayout() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let marker = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let first = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let second = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var inLayout = true
        var callbackDuringLayout = false
        var delivered: [ObjectIdentifier?] = []
        relay.install {
            callbackDuringLayout = inLayout
            delivered.append($0.map(ObjectIdentifier.init))
        }

        // when — stale A and current B are reported before the deferred hop runs.
        relay.report(first, from: marker)
        relay.report(second, from: marker)
        #expect(delivered.isEmpty)
        inLayout = false
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // then
        #expect(!callbackDuringLayout)
        #expect(delivered == [ObjectIdentifier(second)])
    }

}
