import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

/// Synthetic regression for the narrow Activity mount where the newest assistant row is taller
/// than the viewport. It intentionally uses no private task data and no forced layout call.
@MainActor @Suite(.serialized) struct ActivityFeedLongMarkdownHostedTests {
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
            let visible = descendants(document).compactMap { $0 as? ActivityRowGeometry.MeasurementView }
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.intersects(scroll.documentVisibleRect) }
            return visible.count >= 1 && document.bounds.height > scroll.contentView.bounds.height
        }

        // then
        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document).compactMap { $0 as? ActivityRowGeometry.MeasurementView }
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
            let measured = descendants(document).compactMap { $0 as? ActivityRowGeometry.MeasurementView }
                .map { $0.convert($0.bounds, to: document) }
            let visible = measured.filter { $0.intersects(scroll.documentVisibleRect) }
            return measured.count >= 2 && visible.count >= 2
        }

        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document).compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
        let allMeasured = descendants(document).compactMap { $0 as? ActivityRowGeometry.MeasurementView }
            .map { $0.convert($0.bounds, to: document) }
        print("FDC synthetic long-then-finished: document=\(document.bounds), visible=\(scroll.documentVisibleRect), measured=\(allMeasured)")
        withKnownIssue("Issue 39: a tall reply followed by Finished opens with no realized rows") {
            #expect(visible.count >= 2, "Both the tall assistant row and following finished row must be measured in the initial viewport")
        }
    }

    private func markdownBody() -> String {
        var sections = ["# Review notes", "## Findings", "- The first finding keeps the row tall.", "- The second finding contains `inline code`."]
        sections += ["```swift\nlet sample = true\n```", "### Details"]
        sections += (0 ..< 12).map { index in
            "Paragraph \(index): This synthetic assistant response wraps across the narrow Activity reading column and remains taller than the initial viewport. It includes **emphasis**, `tokens`, and enough prose to exercise markdown layout."
        }
        return sections.joined(separator: "\n\n")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
