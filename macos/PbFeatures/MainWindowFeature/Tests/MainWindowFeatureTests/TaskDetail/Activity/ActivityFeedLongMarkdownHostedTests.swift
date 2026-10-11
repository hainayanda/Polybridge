import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

/// Synthetic regression for the narrow Activity mount where the newest assistant row is taller
/// than the viewport. It intentionally uses no private task data and no forced layout call.
@MainActor @Suite(.serialized) struct ActivityFeedLongMarkdownHostedTests {
    @Test func givenEightTallActivityRows_whenTaskDetailMounts_thenBottomAndVisibleGeometryRemainStable() async throws {
        // given — a narrow first mount with a tall latest assistant response and mixed rows.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let longText = String(
            repeating: "A long assistant response wraps in the narrow reading column and includes "
                + "**details**, `tokens`, and changing line lengths. ", count: 10
        )
        let items = tallActivityItems(longText: longText)
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = items
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        var notificationOffsets: [CGFloat] = []
        var notificationHeights: [CGFloat] = []
        var notificationFrames: [[CGRect]] = []
        let boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            guard let scroll = activityScroll(in: controller.view), let document = scroll.documentView,
                  document is NSTableView else { return }
            notificationOffsets.append(scroll.documentVisibleRect.minY)
            notificationHeights.append(document.bounds.height)
            notificationFrames.append(descendants(document)
                .compactMap { $0 as? ActivityRowGeometry.MeasurementView }
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.intersects(scroll.documentVisibleRect) })
        }
        defer { NotificationCenter.default.removeObserver(boundsObserver) }
        // when — mount through the normal run loop and wait for the native table to settle.
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count >= 5 }
        await waitUntil(timeout: 5) { activityScroll(in: controller.view)?.documentView is NSTableView }

        let scroll = try #require(activityScroll(in: controller.view))
        let document = try #require(scroll.documentView)
        let table = try #require(document as? NSTableView)
        scroll.contentView.postsBoundsChangedNotifications = true
        await waitUntil(timeout: 5) { document.bounds.maxY - scroll.documentVisibleRect.maxY <= 3 }
        // Keep a bounded observation window: after the first settle, the test measures whether
        // any residual first-mount motion reverses direction or repeatedly changes height.
        try await Task.sleep(for: .milliseconds(500))
        // then — the feed reaches bottom with visible rows and no oscillating geometry.
        let metrics = firstMountMetrics(offsets: notificationOffsets, heights: notificationHeights,
                                        frames: notificationFrames)
        print(
            "synthetic-first-mount rows=\(table.numberOfRows) notifications=\(notificationOffsets.count) "
                + "reversals=\(metrics.reversals) heightTransitions=\(metrics.heightTransitions) "
                + "frames=\(metrics.visibleFrames.count)"
        )
        #expect(table.numberOfRows >= 5)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY <= 3)
        #expect(!notificationOffsets.isEmpty, "The mounted table must publish bounds notifications")
        #expect(!metrics.visibleFrames.isEmpty, "Notifications must include actual visible row geometry")
        #expect(metrics.reversals == 0)
        #expect(metrics.heightTransitions < 3)
    }

    @Test func givenTwoLatestRowsAndTallMarkdown_whenTaskDetailOpensNarrow_thenVisibleRowsAreMeasured() async throws {
        // given
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let text = markdownBody()
        let prompt = try #require(TaskEvent(line: #"{"v":1,"seq":0,"kind":"user_message","text":"Review this change","source":"initial"}"#))
        let assistantLine = #"{"v":1,"seq":1,"kind":"assistant_text","text":""# + text.replacingOccurrences(of: "\n", with: "\\n") + #""}"#
        let assistant = try #require(TaskEvent(line: assistantLine))
        let events = [prompt, assistant]
        harness.detailBox.value = helper.task(status: "completed")
        harness.eventsBox.value = events
        harness.itemsOverride.value = Timeline.items(from: events)
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        // when — settle through the normal window run loop; never call layoutSubtreeIfNeeded.
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == 2 }
        await waitUntil(timeout: 5) {
            guard let scroll = descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }),
                  let document = scroll.documentView else { return false }
            let visible = descendants(document)
.compactMap { $0 as? ActivityRowGeometry.MeasurementView }
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.intersects(scroll.documentVisibleRect) }
            return visible.count >= 1 && document.bounds.height > scroll.contentView.bounds.height
        }

        // then
        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document)
.compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        #expect(!visible.isEmpty, "The initial narrow viewport must realize at least one Activity row")
    }

    @Test func givenTallAssistantThenSmallFinishedRow_whenTaskDetailOpensNarrow_thenBothInitialRowsAreMeasured() async throws {
        // given — this ordering matches the incident: the long assistant item is followed by
        // the small completion marker.  The completion row must not be allowed to stand in for
        // the preceding row while the lazy stack is still estimating its height.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = [
            PreviewFixtures.textItem(markdownBody(), seq: 1),
            PreviewFixtures.finishedItem(seq: 2)
        ]
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        // Settle only through the normal run loop.  In particular, do not force a SwiftUI layout
        // pass before taking the baseline measurement.
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == 2 }
        await waitUntil(timeout: 5) {
            guard let scroll = descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }),
                  let document = scroll.documentView else { return false }
            let measured = descendants(document)
.compactMap { $0 as? ActivityRowGeometry.MeasurementView }
                .map { $0.convert($0.bounds, to: document) }
            let visible = measured.filter { $0.intersects(scroll.documentVisibleRect) }
            return measured.count >= 2 && visible.count >= 2
        }

        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document)
.compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
        let allMeasured = descendants(document)
.compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
        print("FDC synthetic long-then-finished: document=\(document.bounds), "
            + "visible=\(scroll.documentVisibleRect), measured=\(allMeasured)")
        #expect(visible.count >= 2, "Both the tall assistant row and following finished row must be measured in the initial viewport")
    }

    @Test func givenLatestTallRows_whenOlderHistoryIsPublished_thenLatestRowsRemainAtBottom() async throws {
        // This models the delivery order used by the real task: the newest folded page mounts
        // first, then the older pages are prepended into the same timeline while the feed is
        // already following the live end.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let latest = [
            PreviewFixtures.textItem(markdownBody(), seq: 1),
            PreviewFixtures.finishedItem(seq: 2)
        ]
        let older = groupedOlderHistory()
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = latest
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == latest.count }
        await waitUntil(timeout: 5) { atBottom(in: controller.view) && visibleMeasurementCount(in: controller.view) >= 2 }

        // when — older content is delivered after the newest page has settled.
        harness.itemsOverride.value = older + latest
        harness.itemsSubject.send(older + latest)
        await waitUntil(timeout: 5) {
            harness.sut.timelineWorker == nil
                && harness.sut.timelineModel.rows.count == older.count + latest.count
        }
        await waitUntil(timeout: 5) {
            atBottom(in: controller.view) && visibleMeasurementCount(in: controller.view) >= 2
        }

        // then — publishing history must preserve the live end, including both rows that were
        // visible before the prepend. A List implementation that loses its native scroll identity
        // or restores against an estimated document height fails this check by landing at the top.
        #expect(atBottom(in: controller.view), "Publishing older history must preserve the live bottom")
        #expect(visibleMeasurementCount(in: controller.view) >= 2,
                "The tall latest assistant and following Finished row must remain realized")
    }

    private func markdownBody() -> String {
        var sections = [
            "# Review notes", "## Findings", "- The first finding keeps the row tall.",
            "- The second finding contains `inline code`."
        ]
        sections += ["```swift\nlet sample = true\n```", "### Details"]
        sections += (0 ..< 12).map { index in
            "Paragraph \(index): This synthetic assistant response wraps across the narrow Activity reading column "
                + "and remains taller than the initial viewport. It includes **emphasis**, `tokens`, and enough "
                + "prose to exercise markdown layout."
        }
        return sections.joined(separator: "\n\n")
    }

    private func tallActivityItems(longText: String) -> [TimelineItem] {
        [
            PreviewFixtures.textItem(longText, seq: 1),
            PreviewFixtures.toolItem(tool: "Read", category: "read",
                                     path: "/fictional/Sources/Activity.swift", seq: 2,
                                     callID: "fixture-read-1"),
            PreviewFixtures.toolItem(tool: "Read", category: "read",
                                     path: "/fictional/Tests/Activity.swift", seq: 3,
                                     callID: "fixture-read-2"),
            PreviewFixtures.textItem(longText, seq: 4),
            PreviewFixtures.toolItem(tool: "Bash", category: "shell",
                                     command: "swift test --filter Activity", seq: 5,
                                     callID: "fixture-shell-1"),
            PreviewFixtures.toolItem(tool: "Bash", category: "shell",
                                     command: "swift test --filter ActivityPending", seq: 6,
                                     callID: "fixture-shell-2"),
            PreviewFixtures.finishedItem(seq: 7),
            PreviewFixtures.textItem(longText, seq: 8)
        ]
    }

    private func firstMountMetrics(offsets: [CGFloat], heights: [CGFloat],
                                   frames: [[CGRect]]) -> (reversals: Int, heightTransitions: Int,
                                                            visibleFrames: [[CGRect]]) {
        let directions = zip(offsets, offsets.dropFirst()).compactMap { pair -> Int? in
            let movement = pair.1 - pair.0
            guard abs(movement) > 5 else { return nil }
            return movement > 0 ? 1 : -1
        }
        return (
            zip(directions, directions.dropFirst()).filter { $0 != $1 }.count,
            zip(heights, heights.dropFirst()).filter { abs($1 - $0) > 1 }.count,
            frames.filter { !$0.isEmpty }
        )
    }

    /// The real failing snapshot contains folded runs of adjacent tool calls interspersed with
    /// prose. Keep the public regression on that same row shape so it exercises group identity and
    /// virtualization, rather than only a long flat list of text rows.
    private func groupedOlderHistory() -> [TimelineItem] {
        var items: [TimelineItem] = []
        for group in 0 ..< 5 {
            for member in 0 ..< 4 {
                let seq = group * 20 + member * 2 + 100
                items.append(PreviewFixtures.toolItem(
                    tool: "Read", category: "read", path: "/tmp/history-\(group)-\(member).swift",
                    seq: seq, callID: "history-read-\(group)-\(member)"
                ))
            }
            items.append(PreviewFixtures.textItem("Older history explanation \(group)", seq: group * 20 + 109))
            for member in 0 ..< 3 {
                let seq = group * 20 + member * 2 + 110
                items.append(PreviewFixtures.toolItem(
                    tool: "Bash", category: "shell", command: "swift test --filter History\(group)",
                    seq: seq, callID: "history-shell-\(group)-\(member)"
                ))
            }
            items.append(PreviewFixtures.textItem("Older history checkpoint \(group)", seq: group * 20 + 119))
        }
        return items
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func activityScroll(in view: NSView) -> NSScrollView? {
        descendants(view).compactMap { $0 as? NSScrollView }.first(where: { $0.hasVerticalScroller })
    }

    private func atBottom(in view: NSView) -> Bool {
        guard let scroll = activityScroll(in: view), let document = scroll.documentView else { return false }
        return abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 3
    }

    private func visibleMeasurementCount(in view: NSView) -> Int {
        guard let scroll = activityScroll(in: view), let document = scroll.documentView else { return 0 }
        return descendants(document)
            .compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
            .count
    }

}
