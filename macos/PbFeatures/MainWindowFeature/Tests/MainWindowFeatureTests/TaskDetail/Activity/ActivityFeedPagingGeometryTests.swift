import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - ActivityFeedPagingGeometryTests

extension ActivityFeedReadingGeometryTests {
    @Test func givenPausedFeedNearOlderPageBoundary_whenOlderRowsLoad_thenReadingViewportDoesNotJumpDuringRealization() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let current = pagedRows(prefix: "current", count: 100, sequence: 100)
        let older = pagedRows(prefix: "older", count: 100, sequence: 0)
        let host = NSHostingView(rootView: feed(current, state: state,
            history: EventHistoryState(hasMore: true), onLoadMore: { requests.total += 1; return true }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned && state.followLive.isFollowing }
        try #require(state.viewportPositioned && state.followLive.isFollowing)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        state.followLive.suspend()
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in
            requests.total > 0 && !state.followLive.isFollowing && state.anchor != nil
                && scroll.documentVisibleRect.minY <= 200
        }
        try #require(requests.total > 0)
        try #require(!state.followLive.isFollowing && state.anchor != nil
                         && scroll.documentVisibleRect.minY <= 200)
        let anchor = try #require(state.anchor)
        let recorder = AnchorTraceRecorder(host: host, scroll: scroll, anchorID: anchor.id,
                                           rowIDs: current.map(\.id))
        recorder.capture()
        try #require(recorder.samples.count == 1)

        host.rootView = feed(older + current, state: state,
            history: EventHistoryState(hasMore: false), onLoadMore: { requests.total += 1; return true })
        recorder.rowIDs = (older + current).map(\.id)
        for _ in 0 ..< 30 {
            recorder.capture()
            try await Task.sleep(for: .milliseconds(25))
        }
        await waitUntil(timeout: 5) { @MainActor in
            state.viewportPositioned && !state.followLive.isFollowing && state.anchor != nil
        }
        recorder.capture()
        let trace = recorder.samples
.map {
            String(format: "t=%.3f off=%.1f doc=%.1f rows=%d target=%d native=(%.1f,%.1f,%.1f,%.1f) measured=%.1f",
                   $0.timestamp, $0.offset, $0.documentHeight, $0.tableRows, $0.targetRow,
                   $0.nativeFrame.minX, $0.nativeFrame.minY, $0.nativeFrame.width, $0.nativeFrame.height,
                   $0.relativeOffset)
        }
.joined(separator: " | ")
        try #require(recorder.samples.count >= 4)
        try #require(recorder.samples.count > 1)
        let excursion = recorder.samples.map { abs($0.relativeOffset - anchor.relativeOffset) }.max() ?? 0
        #expect(excursion < 4, "Loading older rows must not visibly jump the retained cell: \(trace)")
    }

    @Test func givenPausedFeedWithUnrealizedRetainedAnchor_whenOlderRowsLoad_thenProxyFallbackRestoresThatAnchor() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let current = pagedRows(prefix: "fallback-current", count: 100, sequence: 100)
        let older = pagedRows(prefix: "fallback-older", count: 100, sequence: 0)
        let host = NSHostingView(rootView: feed(current, state: state,
            history: EventHistoryState(hasMore: true), onLoadMore: { requests.total += 1; return true }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned && state.followLive.isFollowing }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        state.followLive.suspend()
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in requests.total > 0 && !state.followLive.isFollowing }
        try #require(requests.total > 0 && !state.followLive.isFollowing)
        let fallbackID = "fallback-current-50"
        state.anchor = ParallelVerticalAnchor(id: fallbackID, index: 50, relativeOffset: 18)
        host.rootView = feed(older + current, state: state,
            history: EventHistoryState(hasMore: false), onLoadMore: { requests.total += 1; return true })
        await waitUntil(timeout: 5) { @MainActor in
            guard let document = scroll.documentView as? NSTableView else { return false }
            let rowIndex = document.numberOfRows - 200 - 1 + 150
            return state.viewportPositioned && !state.followLive.isFollowing
                && mountedMeasurementFrame(forNativeRow: rowIndex, host: host, table: document, scroll: scroll) != nil
        }
        let table = try #require(scroll.documentView as? NSTableView)
        let rowIndex = table.numberOfRows - 200 - 1 + 150
        let frame = try #require(mountedMeasurementFrame(forNativeRow: rowIndex, host: host,
                                                         table: table, scroll: scroll))
        #expect(state.anchor?.id == fallbackID)
        #expect(abs(frame.minY - scroll.documentVisibleRect.minY - 18) < 4)
    }

    @Test func givenOlderPagePending_whenContinuedWheelMovesUp_thenLatestReadingPositionWins() async throws {
        try await exerciseContinuedWheel(direction: .up)
    }

    @Test func givenOlderPagePending_whenContinuedWheelMovesDown_thenLatestReadingPositionWins() async throws {
        try await exerciseContinuedWheel(direction: .down)
    }

    func verifyPublishedHistory(host: NSView, state: ParallelColumnUIState,
                               scroll: NSScrollView, pausedAnchor: ParallelVerticalAnchor,
                               generationBeforePublication: Int) async throws {
        await waitUntil(timeout: 5) {
            @MainActor in measurementGeneration(in: host) > generationBeforePublication
                && state.viewportPositioned && !state.followLive.isFollowing
                && state.anchor?.id == pausedAnchor.id
                && firstVisibleMeasurementFrame(in: host, scroll: scroll).map {
                    abs($0.minY - scroll.documentVisibleRect.minY - pausedAnchor.relativeOffset) < 3
                } == true
                && abs(state.scrollOffset - scroll.documentVisibleRect.minY) < 2
        }
        try #require(measurementGeneration(in: host) > generationBeforePublication)
        #expect(state.viewportPositioned)
        #expect(!state.followLive.isFollowing)
        let restoredAnchor = try #require(state.anchor)
        #expect(restoredAnchor.id == pausedAnchor.id)
        let restoredViewport = scroll.documentVisibleRect
        let restoredRowFrame = try #require(firstVisibleMeasurementFrame(in: host, scroll: scroll))
        #expect(abs(restoredRowFrame.minY - restoredViewport.minY - pausedAnchor.relativeOffset) < 3)
        #expect(abs(restoredAnchor.relativeOffset - pausedAnchor.relativeOffset) < 3)
        #expect(abs(state.scrollOffset - scroll.documentVisibleRect.minY) < 2)
    }

    @MainActor final class AnchorTraceRecorder {
        struct Sample {
            let timestamp: TimeInterval
            let offset: CGFloat
            let documentHeight: CGFloat
            let tableRows: Int
            let targetRow: Int
            let nativeFrame: CGRect
            let relativeOffset: CGFloat
        }

        private(set) var samples: [Sample] = []
        private weak var host: NSView?
        private weak var scroll: NSScrollView?
        private let anchorID: String
        var rowIDs: [String]

        init(host: NSView, scroll: NSScrollView, anchorID: String, rowIDs: [String]) {
            self.host = host
            self.scroll = scroll
            self.anchorID = anchorID
            self.rowIDs = rowIDs
        }

        func capture() {
            guard let host, let scroll, let document = scroll.documentView,
                  let table = document as? NSTableView,
                  let anchorIndex = rowIDs.firstIndex(of: anchorID) else { return }
            let headerOffset = table.numberOfRows - rowIDs.count - 1
            let targetRow = headerOffset + anchorIndex
            guard let view = descendants(host)
.compactMap({ $0 as? ActivityRowGeometry.MeasurementView })
                .first(where: { table.row(for: $0) == targetRow }) else { return }
            let frame = view.convert(view.bounds, to: document)
            let nativeFrame = table.rect(ofRow: targetRow)
            guard frame.width > 0, frame.height > 0, frame.intersects(scroll.documentVisibleRect) else { return }
            samples.append(Sample(timestamp: ProcessInfo.processInfo.systemUptime,
                                  offset: scroll.documentVisibleRect.minY,
                                  documentHeight: document.bounds.height,
                                  tableRows: table.numberOfRows,
                                  targetRow: targetRow,
                                  nativeFrame: nativeFrame,
                                  relativeOffset: frame.minY - scroll.documentVisibleRect.minY))
        }

        private func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
    }
}
