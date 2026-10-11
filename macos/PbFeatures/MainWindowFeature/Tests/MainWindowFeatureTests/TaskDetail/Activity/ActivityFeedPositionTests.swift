import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - ActivityFeedPositionTests

@MainActor @Suite(.serialized) struct ActivityFeedPositionTests {
    @Test func givenRowMeasuredBeforeResize_whenViewportCallbackArrives_thenWidthDeltaIsAppliedOnce() throws {
        let harness = try NativeGeometryHarness()
        defer { harness.close() }
        let position = ActivityFeedPosition()

        try #require(position.record(
            ActivityRowFrameSample(
                frame: CGRect(x: 0, y: 120, width: 300, height: 80),
                viewportWidth: 400,
                document: harness.documentA
            ),
            for: "anchor",
            nativeIdentity: harness.identity
        ))

        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == 500)
    }

    @Test func givenRowMeasuredAfterResizeBeforeViewportCallback_whenViewportCallbackArrives_thenWidthMatchesEarlierOrdering() throws {
        let harness = try NativeGeometryHarness()
        defer { harness.close() }
        let position = ActivityFeedPosition()

        try #require(position.record(
            ActivityRowFrameSample(
                frame: CGRect(x: 0, y: 120, width: 500, height: 80),
                viewportWidth: 600,
                document: harness.documentA
            ),
            for: "anchor",
            nativeIdentity: harness.identity
        ))

        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == 500)
    }

    @Test func givenUnchangedFrame_whenViewportWidthChanges_thenPairedMetadataStillPublishes() throws {
        let harness = try NativeGeometryHarness()
        defer { harness.close() }
        let position = ActivityFeedPosition()
        let frame = CGRect(x: 0, y: 120, width: 300, height: 80)

        try #require(position.record(ActivityRowFrameSample(frame: frame, viewportWidth: 400,
                                                             document: harness.documentA),
                                     for: "anchor", nativeIdentity: harness.identity))
        #expect(position.record(ActivityRowFrameSample(frame: frame, viewportWidth: 450,
                                                       document: harness.documentA),
                                for: "anchor", nativeIdentity: harness.identity))
        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == 450)
    }

    @Test func givenReplacedNativeDocument_whenOldSampleArrives_thenSampleIsRejectedAndCacheIsCleared() throws {
        let harness = try NativeGeometryHarness()
        defer { harness.close() }
        let position = ActivityFeedPosition()
        let old = ActivityRowFrameSample(frame: CGRect(x: 0, y: 120, width: 300, height: 80),
                                         viewportWidth: 400, document: harness.documentA)
        try #require(position.record(old, for: "anchor", nativeIdentity: harness.identity))

        harness.identity.deliver(harness.scrollB)
        #expect(!position.record(old, for: "anchor", nativeIdentity: harness.identity))
        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == nil)
    }

    @Test func givenRecordedDocument_whenNativeTargetIsDetached_thenPositionDoesNotRetainDocument() async throws {
        _ = NSApplication.shared
        let identity = ParallelScrollNativeIdentity()
        let position = ActivityFeedPosition()
        weak var weakDocument: NSView?
        do {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
            weakDocument = document
            scroll.documentView = document
            identity.deliver(scroll)
            try #require(position.record(ActivityRowFrameSample(frame: .zero, viewportWidth: 400,
                                                                 document: document),
                                         for: "anchor", nativeIdentity: identity))
            identity.deliver(nil)
            scroll.documentView = nil
        }
        await Task.yield()
        #expect(weakDocument == nil)
    }
}

@MainActor @Suite struct ActivityRowWidthRestorationTests {
    @Test func givenNoMeasuredAnchor_whenResizeArrives_thenNoWidthIsInvented() {
        var restoration = ActivityRowWidthRestoration()

        restoration.resize(measuredWidth: nil, previousViewportWidth: 400,
                           viewportWidth: 600, restoring: true)

        #expect(restoration.width == nil)
        #expect(restoration.accepts(rowWidth: nil))
    }

    @Test func givenMeasuredWidthAtA_whenCacheClearsBeforeBAndCArrive_thenPendingWidthAdvancesToC() throws {
        let harness = try NativeGeometryHarness()
        defer { harness.close() }
        let position = ActivityFeedPosition()
        try #require(position.record(
            ActivityRowFrameSample(
                frame: CGRect(x: 0, y: 120, width: 500, height: 80),
                viewportWidth: 400,
                document: harness.documentA
            ),
            for: "anchor",
            nativeIdentity: harness.identity
        ))
        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == 700)
        position.clearFrames()
        #expect(position.expectedRowWidth(for: "anchor", viewportWidth: 600,
                                          nativeIdentity: harness.identity) == nil)

        var restoration = ActivityRowWidthRestoration()

        restoration.resize(measuredWidth: 500, previousViewportWidth: 400,
                           viewportWidth: 600, restoring: true)
        restoration.resize(measuredWidth: nil, previousViewportWidth: 600,
                           viewportWidth: 340, restoring: true)

        #expect(restoration.width == 240)
        #expect(!restoration.accepts(rowWidth: 500), "The stale B-width sample must be rejected")
        #expect(restoration.accepts(rowWidth: 240), "The fresh C-width sample must be accepted")
    }

    @Test func givenPendingWidth_whenFollowingResumes_thenLaterResizeDoesNotCarryStaleWidth() {
        var restoration = ActivityRowWidthRestoration()
        restoration.resize(measuredWidth: 500, previousViewportWidth: 400,
                           viewportWidth: 600, restoring: true)

        restoration.finish(restoring: false)
        restoration.resize(measuredWidth: nil, previousViewportWidth: 600,
                           viewportWidth: 340, restoring: false)

        #expect(restoration.width == nil)
        #expect(restoration.accepts(rowWidth: nil))
    }
}

@MainActor
private final class NativeGeometryHarness {
    let identity = ParallelScrollNativeIdentity()
    let scrollA = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let scrollB = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    private(set) var documentA: NSView

    init() throws {
        _ = NSApplication.shared
        self.documentA = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scrollA.documentView = documentA
        scrollB.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        identity.deliver(scrollA)
    }

    func close() {
        scrollA.documentView = nil
        scrollB.documentView = nil
    }
}
