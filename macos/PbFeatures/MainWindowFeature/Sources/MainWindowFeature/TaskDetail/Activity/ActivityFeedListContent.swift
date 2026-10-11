import AppKit
import MonitorCore
import PbUI
import SwiftUI

/// Explicit rendering values keep native scroll geometry out of the List dependency graph.
struct ActivityFeedListRenderInputs: Equatable {
    enum Header: Equatable { case none, loading, error(String), beginning }
    let rows: [ActivityRow]
    let start: Date?
    let header: Header
    let emptyText: String?
    let horizontalPadding: CGFloat
    let showsPromptBubble: Bool
    let expandedGroups: Set<String>
    let generation: Int
    let fadeIDs: Set<String>
    let hasTail: Bool
}

/// Latest callbacks are refreshed by the parent without publishing List dependencies.
@MainActor
final class ActivityFeedListCallbacks {
    func clearActions() {
        onFrame = nil
        onAppear = nil
        onDisclosure = nil
        onRetry = nil
        onSelectChildTask = nil
    }

    var onNativeIdentity: ((NSScrollView?) -> Void)?
    var onFrame: ((String, Int, ActivityRowFrameSample) -> Void)?
    var onAppear: ((String) -> Void)?
    var onDisclosure: ((String) -> Void)?
    var onRetry: (() -> Void)?
    var onSelectChildTask: ((String) -> Void)?
}

struct ActivityFeedListContent: View, @MainActor Equatable {
    let inputs: ActivityFeedListRenderInputs
    let callbacks: ActivityFeedListCallbacks
    let measurements: ActivityRowMeasurements
    let tailStore: ActivityFeedTailStore

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputs == rhs.inputs && lhs.callbacks === rhs.callbacks && lhs.measurements === rhs.measurements && lhs.tailStore === rhs.tailStore
    }

    private var hasHeader: Bool { inputs.header != .none }
    private var hasTail: Bool { inputs.hasTail }
    private var hasContent: Bool { hasHeader || inputs.emptyText != nil || !inputs.rows.isEmpty }

    var body: some View {
        List {
            if hasHeader { header.modifier(Placement(top: PbRadius.Metrics.spacing12, bottom: 0, padding: inputs.horizontalPadding)) }
            if let text = inputs.emptyText {
                Text(text)
.font(.pb(.body))
.foregroundStyle(Color.secondaryText)
                    .modifier(Placement(top: hasHeader ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                                        bottom: 0, padding: inputs.horizontalPadding))
            }
            ForEach(inputs.rows) { row in
                rowView(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ActivityRowGeometry(generation: inputs.generation, measurements: measurements, stableID: row.id) { sample in
                        callbacks.onFrame?(row.id, inputs.generation, sample)
                    })
                    .pbFadeIn(animate: inputs.fadeIDs.contains(row.id))
                    .onAppear { callbacks.onAppear?(row.id) }
                    .modifier(Placement(top: !hasHeader && inputs.emptyText == nil && row.id == inputs.rows.first?.id
                                        ? PbRadius.Metrics.spacing12 : PbRadius.Metrics.spacing20,
                                        bottom: 0, padding: inputs.horizontalPadding))
            }
            if hasTail {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing20) {
                    ActivityFeedObservedTailContent(store: tailStore, callbacks: callbacks)
                }
                    .modifier(Placement(top: hasContent ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                                        bottom: 0, padding: inputs.horizontalPadding))
            }
            Color.clear
.frame(height: PbRadius.Metrics.hairlineStroke)
                .modifier(Placement(top: hasContent || hasTail ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                                    bottom: PbRadius.Metrics.spacing12, padding: inputs.horizontalPadding))
                .id("activity-feed-bottom")
        }
        .listStyle(.plain)
        .contentMargins(PbRadius.Metrics.zero, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, PbRadius.Metrics.hairlineStroke)
        .scrollContentBackground(.hidden)
        .scrollChromeScope(onNativeScrollView: { callbacks.onNativeIdentity?($0) })
    }

    @ViewBuilder private var header: some View {
        switch inputs.header {
        case .none: EmptyView()
        case .loading: LoadingLabel("Loading activity…")
        case .error(let error):
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                Text(error).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Button("Retry older activity") { callbacks.onRetry?() }.buttonStyle(.link)
            }
        case .beginning: Text("Beginning of activity").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private func rowView(_ row: ActivityRow) -> some View {
        switch row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: inputs.start, isExpanded: inputs.expandedGroups.contains(group.id)) {
                callbacks.onDisclosure?(group.id)
            }
        case .single(let row):
            switch row.kind {
            case .separator(let text): TurnSeparatorRow(text: text, timestamp: row.timestamp)
            case .item(let item): TimelineRow(model: TimelineRowModel(item: item, start: inputs.start, live: row.live,
                                                                    showsPromptBubble: inputs.showsPromptBubble))
            }
        }
    }

    private struct Placement: ViewModifier {
        let top: CGFloat
        let bottom: CGFloat
        let padding: CGFloat
        func body(content: Content) -> some View {
            content.padding(EdgeInsets(top: top, leading: padding, bottom: bottom, trailing: padding))
                .listRowInsets(EdgeInsets())
.listRowSeparator(.hidden)
.listRowBackground(Color.clear)
        }
    }
}

private struct ActivityFeedObservedTailContent: View {
    let store: ActivityFeedTailStore
    let callbacks: ActivityFeedListCallbacks
    var body: some View { ActivityFeedTailContent(presentation: store.presentation, callbacks: callbacks) }
}

private struct ActivityFeedTailContent: View {
    let presentation: ActivityFeedTailPresentation
    let callbacks: ActivityFeedListCallbacks
    @ViewBuilder var body: some View {
        switch presentation {
        case .absent: EmptyView()
        case .plainText(let text): Text(text)
        case .standard(let standard):
            if let strip = standard.subTaskStrip {
                SubTaskStripView(model: SubTaskStripModel(
                    children: strip.children.map { SubTaskEntry(task: $0.task, title: $0.title) }, start: strip.start,
                    onSelectTask: { callbacks.onSelectChildTask?($0) }
                ))
            }
            ForEach(standard.pendingMessages) { message in
                PromptBubbleView(text: message.text, caption: "Pending", isPending: true)
            }
            if let line = standard.liveStep {
                switch line.indicator {
                case .singleDot: LiveStepLineView(text: line.text)
                case .threeDots: LiveStepLineView(text: line.text, indicator: .threeDots)
                }
            }
        }
    }

}
