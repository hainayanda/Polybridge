import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import Testing

// MARK: - ParallelScrollNativeIdentityTests

@MainActor @Suite(.serialized) struct ParallelScrollNativeIdentityTests {
    @Test func givenTargetA_whenIdentityBecomesNilAndThenTargetB_whenInputsStayUnchanged_thenOnlyTheCurrentTargetPublishes() async throws {
        // given
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var positions: [CGFloat] = []
        var viewportSizes: [CGSize] = []
        view.onPosition = { offset, _, _ in positions.append(offset) }
        view.onViewportSize = { viewportSizes.append($0) }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        // when — A is active, then detached, then B is adopted without a configure-input change.
        let beforeA = positions.count
        harness.move(harness.targetA, to: 40)
        await waitUntil(timeout: 2) { positions.count > beforeA }
        let beforeNil = positions.count
        identity.deliver(nil)
        harness.move(harness.targetA, to: 80)
        await Task.yield()
        #expect(positions.count == beforeNil)
        identity.deliver(harness.targetB)
        await waitUntil(timeout: 2) { positions.count > beforeNil }
        let beforeB = positions.count
        harness.move(harness.targetB, to: 120)
        await waitUntil(timeout: 2) { positions.count > beforeB }
        let beforeResize = viewportSizes.count
        harness.resize(harness.targetB, height: 140)
        await waitUntil(timeout: 2) { viewportSizes.count > beforeResize }

        // then — old-target notifications stop at nil, and the replacement target is observable.
        #expect(positions.count > beforeB)
        #expect(viewportSizes.count > beforeResize)
    }

    @Test func givenRestorationQueuedBeforeNativeDiscovery_whenTargetArrives_thenPendingOffsetIsApplied() async throws {
        // given
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var offsets: [CGFloat] = []
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.usesNativeIdentity = true
        view.configure(ids: [], stride: 0, restorationOffset: 80, restorationActive: true)
        identity.register(view)

        // when — discovery is delayed until after the observer already owns a restoration request.
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 80) < 2 } }

        // then
        #expect(offsets.contains { abs($0 - 80) < 2 })
    }

    @Test func givenNativeTargetWithoutDocument_whenDocumentArrives_thenPendingTargetAttaches() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var positions: [CGFloat] = []
        view.onPosition = { offset, _, _ in positions.append(offset) }
        view.usesNativeIdentity = true
        view.configure(ids: [], stride: 0, restorationOffset: 90, restorationActive: true)
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        // when — A is replaced by a scoped target whose document is not ready yet.
        harness.targetB.documentView = nil
        identity.deliver(harness.targetB)
        let beforeDetach = positions.count
        harness.move(harness.targetA, to: 80)
        await Task.yield()
        #expect(positions.count == beforeDetach)
        positions.removeAll()

        harness.targetB.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1000))
        // A later List update re-runs the bounded lifecycle adoption for the same identity after
        // its document exists; it must apply the pending restoration independently of A's history.
        view.configure(ids: ["ready"], stride: 0, restorationOffset: 90, restorationActive: true)
        await waitUntil(timeout: 2) { positions.contains { abs($0 - 90) < 2 } }

        #expect(positions.contains { abs($0 - 90) < 2 })
    }

    @Test func givenSameNativeScroll_whenDocumentIsReplaced_thenOnlyReplacementDocumentPublishes() async throws {
        // given — the scoped identity remains the same NSScrollView while List replaces its
        // document view. Keep both documents alive so notifications from the retired one can be
        // distinguished from notifications on the replacement.
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var positions: [(offset: CGFloat, length: CGFloat, viewport: CGFloat)] = []
        view.onPosition = { offset, length, viewport in positions.append((offset, length, viewport)) }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        let retiredDocument = try #require(harness.targetA.documentView)
        let replacementDocument = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 760))
        harness.targetA.documentView = replacementDocument
        positions.removeAll()

        // when — the relay re-delivers the same scroll identity after its document changes.
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }
        let replacementBaseline = try #require(positions.last)
        #expect(replacementBaseline.length == 760)
        await Task.yield()
        positions.removeAll()

        // Change B without posting its frame notification first. A stale subscription to A must
        // not report B's changed geometry when A later emits a notification.
        replacementDocument.postsBoundsChangedNotifications = false
        replacementDocument.setBoundsSize(NSSize(width: 220, height: 820))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: retiredDocument)
        await Task.yield()
        #expect(positions.isEmpty)

        replacementDocument.postsBoundsChangedNotifications = true
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: replacementDocument)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        // then — the callback is sourced from B, with its new document height, rather than A's.
        #expect(positions.count == 1)
        let sample = try #require(positions.last)
        #expect(sample.length == 820)

        // Repeating B's notification without changing its geometry must remain deduplicated.
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: replacementDocument)
        await Task.yield()
        #expect(positions.count == 1)
    }

    @Test func givenPendingRestorationDuringSameScrollNilGap_whenReplacementArrives_thenOffsetSurvives() async throws {
        // given — the scroll identity remains adopted while its document is temporarily absent.
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var offsets: [CGFloat] = []
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !offsets.isEmpty }

        // when — request restoration while A is absent, then install B on the same scroll view.
        harness.targetA.documentView = nil
        identity.deliver(harness.targetA)
        view.configure(ids: [], stride: 0, restorationOffset: 400, restorationActive: true)
        let replacementDocument = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1600))
        harness.targetA.documentView = replacementDocument
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 400) < 2 } }

        // then — the request survives the nil-document interval and lands on B.
        #expect(offsets.contains { abs($0 - 400) < 2 })
    }

    @Test func givenLiveScrollEndsDuringSameDocumentNilGap_whenReplacementReattaches_thenLayoutMoveDoesNotSignalIntent() async throws {
        // given — the scoped scroll remains the same while its document is temporarily absent;
        // the live-scroll lifecycle must remain subscribed across that document gap.
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var offsets: [CGFloat] = []
        var intents = 0
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.onUpwardIntent = { intents += 1 }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !offsets.isEmpty }

        // when — a live scroll starts before A disappears, then ends while the same scroll has
        // no document, and B is installed before an upward layout movement occurs.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        harness.targetA.documentView = nil
        identity.deliver(harness.targetA)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: harness.targetA)
        let replacementDocument = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1600))
        harness.targetA.documentView = replacementDocument
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.count > 1 }

        // Move the native clip view upward as a layout change. If didEnd was lost in the nil gap,
        // this movement is misread as intent.
        harness.move(harness.targetA, to: 940)
        await waitUntil(timeout: 2) { offsets.count > 2 }
        let intentsBeforeLayout = intents
        let callbacksBeforeLayout = offsets.count
        harness.move(harness.targetA, to: 1040)
        await waitUntil(timeout: 2) { offsets.count > callbacksBeforeLayout }
        try #require(offsets.count > callbacksBeforeLayout, "The upward layout movement must be observed")

        // then — the ended live scroll remains ended, so the layout movement produces no intent.
        #expect(intents == intentsBeforeLayout)
    }

    @Test func givenOwnNativeLiveScroll_whenEnded_thenLaterLayoutMovementDoesNotPauseFeed() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var intents = 0
        var positions: [CGFloat] = []
        view.onUpwardIntent = { intents += 1 }
        view.onPosition = { offset, _, _ in positions.append(offset) }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        harness.move(harness.targetA, to: 100)
        await waitUntil(timeout: 2) { positions.count > 1 }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        let intentsBeforeMove = intents
        harness.move(harness.targetA, to: 200)
        await waitUntil(timeout: 2) { intents > intentsBeforeMove }
        let intentsBeforeEnd = intents
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: harness.targetA)
        harness.move(harness.targetA, to: 300)
        await waitUntil(timeout: 2) { positions.count > 2 }

        #expect(intents == intentsBeforeEnd)
    }

    @Test func givenNativeLiveScrollWithoutBoundsNotification_whenIdentityReasserts_thenUpwardMoveWinsOverRestoration() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var intents = 0
        var offsets: [CGFloat] = []
        view.onUpwardIntent = { intents += 1 }
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.usesNativeIdentity = true
        view.configure(ids: [], stride: 0, restorationOffset: 400, restorationActive: true)
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 400) < 2 } }
        try #require(offsets.contains { abs($0 - 400) < 2 }, "Initial restoration must settle before the live move")

        harness.targetA.contentView.postsBoundsChangedNotifications = false
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        // The fixture document is non-flipped: native y=740 corresponds to logical reading
        // offset 100 in a 1,000-point document with a 160-point viewport.
        harness.targetA.contentView.scroll(to: CGPoint(x: 0, y: 740))
        harness.targetA.reflectScrolledClipView(harness.targetA.contentView)
        view.adoptNativeIdentity(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 100) < 2 } }

        #expect(intents > 0)
        let latestOffset = try #require(offsets.last)
        #expect(abs(latestOffset - 100) < 2)
    }

    @Test func givenOuterLiveScrollNotification_whenOwnTargetMovesUp_thenIntentRemainsScoped() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var intents = 0
        var positions: [CGFloat] = []
        view.onUpwardIntent = { intents += 1 }
        view.onPosition = { offset, _, _ in positions.append(offset) }
        view.usesNativeIdentity = true
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !positions.isEmpty }

        harness.move(harness.targetA, to: 100)
        await waitUntil(timeout: 2) { positions.count > 1 }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetB)
        harness.move(harness.targetA, to: 200)
        await waitUntil(timeout: 2) { positions.count > 2 }
        #expect(intents == 0)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        harness.move(harness.targetA, to: 300)
        await waitUntil(timeout: 2) { intents > 0 }
        #expect(intents > 0)
    }

    @Test func givenIdentityModeInsideHorizontalOuterScroll_whenNoNativeTargetIsDelivered_thenObserverFailsClosed() async throws {
        // given
        _ = NSApplication.shared
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        outer.hasHorizontalScroller = true
        outer.hasVerticalScroller = false
        outer.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 120))
        let root = NSView(frame: outer.frame)
        let view = ParallelScrollObservationView()
        view.axis = .vertical
        view.usesNativeIdentity = true
        var callbackCount = 0
        view.onPosition = { _, _, _ in callbackCount += 1 }
        root.addSubview(outer)
        outer.documentView?.addSubview(view)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        view.adoptNativeIdentity(nil)

        // when — the enclosing horizontal container moves.
        outer.contentView.scroll(to: CGPoint(x: 100, y: 0))
        outer.reflectScrolledClipView(outer.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: outer.contentView)
        await Task.yield()

        // then — identity mode never falls back to the enclosing horizontal scroll view.
        #expect(callbackCount == 0)
    }

    @Test func givenAdoptedTargetWithNativeInsets_whenObserverReportsAndThenTeardowns_thenInsetsAreZeroAndNativeSpacingIsPreserved() async throws {
        // given
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness(insets: NSEdgeInsets(top: 8, left: 4, bottom: 12, right: 2))
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        let table = NSTableView(frame: harness.targetA.documentView?.frame ?? .zero)
        table.intercellSpacing = NSSize(width: 17, height: 3)
        harness.targetA.documentView = table
        try #require(table.intercellSpacing == NSSize(width: 17, height: 3))
        view.usesNativeIdentity = true
        identity.register(view)

        // when
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { insetsEqual(harness.targetA.contentInsets, NSEdgeInsetsZero) }
        try #require(insetsEqual(harness.targetA.contentInsets, NSEdgeInsetsZero))
        try #require(!harness.targetA.automaticallyAdjustsContentInsets)
        try #require(table.intercellSpacing == NSSize(width: 17, height: 3))
        harness.targetA.contentInsets = NSEdgeInsets(top: 3, left: 2, bottom: 4, right: 1)
        harness.targetA.automaticallyAdjustsContentInsets = true
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: harness.targetA.contentView)
        await waitUntil(timeout: 2) { insetsEqual(harness.targetA.contentInsets, NSEdgeInsetsZero) }
        try #require(insetsEqual(harness.targetA.contentInsets, NSEdgeInsetsZero))
        try #require(table.intercellSpacing == NSSize(width: 17, height: 3))
        view.teardownObservation()

        // then
        #expect(insetsEqual(harness.targetA.contentInsets, NSEdgeInsets(top: 8, left: 4, bottom: 12, right: 2)))
        #expect(table.intercellSpacing == NSSize(width: 17, height: 3))
    }

    @Test func givenMountedObserverIsDismantled_whenIdentityChangesBeforeReplacementMount_thenReplacementAdoptsKnownTarget() async throws {
        // given — this follows the representable lifecycle: binding nil unregisters the old view
        // before dismantle, while the holder retains the last scoped identity for remount.
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let oldView = harness.makeObserver()
        var oldPositions: [CGFloat] = []
        oldView.onPosition = { offset, _, _ in oldPositions.append(offset) }
        oldView.usesNativeIdentity = true
        oldView.bindNativeIdentity(identity)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { !oldPositions.isEmpty }

        // when — the old representable is dismantled, then the relay discloses B before SwiftUI
        // has mounted the replacement observer.
        ParallelScrollObserver.dismantleNSView(oldView, coordinator: ())
        let oldCount = oldPositions.count
        identity.deliver(harness.targetB)
        harness.move(harness.targetA, to: 80)
        await Task.yield()
        #expect(oldPositions.count == oldCount)

        let replacement = harness.makeObserver()
        var replacementPositions: [CGFloat] = []
        replacement.onPosition = { offset, _, _ in replacementPositions.append(offset) }
        replacement.usesNativeIdentity = true
        replacement.bindNativeIdentity(identity)
        await waitUntil(timeout: 2) { !replacementPositions.isEmpty }

        // then — registration replays the known B identity without another relay delivery.
        let beforeB = replacementPositions.count
        harness.move(harness.targetB, to: 120)
        await waitUntil(timeout: 2) { replacementPositions.count > beforeB }
        #expect(replacementPositions.count > beforeB)
    }

    @Test func givenLegacyVerticalScroller_whenTestingPageUpTrackPart_thenTestPartReceivesWindowCoordinates() async throws {
        // NSScroller.testPart(_:) documents its argument in window coordinates. Keep this
        // contract executable because the local scroller coordinate space is easy to pass by
        // mistake when handling a native List's page-up click.
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 120, y: 70, width: 240, height: 180))
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1200))
        root.addSubview(scroll)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scroller = try #require(scroll.verticalScroller)
        try #require(scroller.isHidden == false)
        try #require(scroller.bounds.width > 0)
        try #require(scroller.bounds.height > 0)

        let pageRect = scroller.rect(for: .decrementPage)
        try #require(pageRect.width > 0)
        try #require(pageRect.height > 0)
        let localPoint = NSPoint(x: pageRect.midX, y: pageRect.midY)
        let windowPoint = scroller.convert(localPoint, to: nil)
        try #require(windowPoint != localPoint)

        let windowPart = scroller.testPart(windowPoint)
        let localPart = scroller.testPart(localPoint)
        #expect(windowPart == .decrementPage)
        #expect(localPart != windowPart)
    }
}

private func insetsEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
    lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && lhs.right == rhs.right
}

// MARK: - Fixture

@MainActor private final class NativeIdentityHarness {
    let root: NSView
    let window: NSWindow
    let targetA: NSScrollView
    let targetB: NSScrollView

    init(insets: NSEdgeInsets = NSEdgeInsets()) throws {
        self.root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        self.targetA = Self.scroll(insets: insets, x: 0)
        self.targetB = Self.scroll(insets: insets, x: 260)
        root.addSubview(targetA)
        root.addSubview(targetB)
        self.window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
    }

    func makeObserver() -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        view.axis = .vertical
        root.addSubview(view)
        return view
    }

    func move(_ scroll: NSScrollView, to offset: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func resize(_ scroll: NSScrollView, height: CGFloat) {
        var frame = scroll.frame
        frame.size.height = height
        scroll.setFrameSize(frame.size)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }

    func close() { window.contentView = nil; window.close() }

    private static func scroll(insets: NSEdgeInsets, x: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: 220, height: 160))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.contentInsets = insets
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1000))
        return scroll
    }
}
