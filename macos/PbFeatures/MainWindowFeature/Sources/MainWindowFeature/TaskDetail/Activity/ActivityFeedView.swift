import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedPosition

@MainActor
private final class ActivityFeedPosition {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    /// Measurements support reading restoration without invalidating the lazy feed's view graph.
    var frames: [String: CGRect] = [:]
    let measurements = ActivityRowMeasurements()
    var pagingTask: Task<Void, Never>?
}

// MARK: - ActivityFeedKey

private struct ActivityFeedKey: Equatable {
    let nativeViewportReady: Bool
    let realizedLastRowID: String?
    let rows: [ActivityRow]
    let tail: ActivityFeedTail
    let showsPromptBubble: Bool
    let expandedGroups: Set<String>
    let viewport: CGSize
    let history: EventHistoryState
    let loading: Bool
    let visible: Bool
    let paginationRevision: Int
    let restoring: Bool
}

// MARK: - ActivityFeedTail

struct ActivityFeedTail: Equatable {
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var children: [TaskDetailTimelineChild] = []
}

// MARK: - ActivityFeedView

/// Shared reading, progressive reveal and older-page behavior across activity surfaces.
struct ActivityFeedView<Tail: View>: View {
    let rows: [ActivityRow]
    let start: Date?
    let history: EventHistoryState
    let isLoading: Bool
    var tailValue = ActivityFeedTail()
    var paginationRevision = 0
    var isVisible = true
    var emptyText: String?
    var horizontalPadding: CGFloat = PbRadius.Metrics.zero
    /// Task detail owns its started-row prompt; Parallel owns it in the toggled column header.
    var showsPromptBubble = true
    let state: ParallelColumnUIState
    let onLoadMore: (() -> Bool)?
    @ViewBuilder let tail: () -> Tail

    @State private var measurementGeneration = 0
    @State private var viewportSize: CGSize = .zero
    @State private var nativeViewportReady = false
    @State private var realizedLastRowID: String?
    @State private var position = ActivityFeedPosition()
    /// Weak relay endpoint between the List's scoped native identity and its scroll observer;
    /// owned here so it lives exactly as long as this feed instance.
    @State private var nativeIdentity = ParallelScrollNativeIdentity()
    @State private var pendingReadingCapture = true
    @State private var positioned = false
    @State private var followingLayout = true
    @State private var restoring = true
    @State private var targetOffset: CGFloat?
    @State private var restorationRowWidth: CGFloat?
    @State private var restorationTiming: UInt64?
    @State private var shortFillBudget = ActivityShortFillBudget()
    @State private var waitingForPage = false
    @State private var requestedIDs: [String] = []
    @State private var rejectedPageIDs: [String]?
    @State private var sawLoading = false
    @State private var seenIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var bottomID: String { "activity-feed-bottom" }
    private var ids: [String] { rows.map(\.id) }
    private var shown: [ActivityRow] {
        Array(rows.dropFirst(ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            feedList
                .task(id: ActivityFeedKey(nativeViewportReady: nativeViewportReady, realizedLastRowID: realizedLastRowID,
                                         rows: shown, tail: tailValue, showsPromptBubble: showsPromptBubble,
                                         expandedGroups: state.expandedGroups, viewport: viewportSize, history: history,
                                         loading: isLoading, visible: isVisible, paginationRevision: paginationRevision, restoring: restoring)) {
                    await settle(proxy)
                }
                .onDisappear { position.pagingTask?.cancel(); position.pagingTask = nil }
                .onChange(of: rows) { old, next in
                    if state.followLive.isFollowing { followingLayout = true }
                    preserveRegroupedAnchor(old: old, next: next)
                    if !state.followLive.isFollowing { beginRestoration() }
                    if waitingForPage, requestedIDs != ids {
                        state.retainedFirstID = next.first?.id
                        waitingForPage = false
                    }
                }
                .onChange(of: tailValue) { _, _ in
                    if state.followLive.isFollowing { followingLayout = true } else { beginRestoration() }
                }
                .onChange(of: paginationRevision) { _, _ in
                    rejectedPageIDs = nil
                    waitingForPage = false
                    sawLoading = false
                    if !state.followLive.isFollowing { beginRestoration() }
                    if !rows.isEmpty { state.retainedFirstID = rows.first?.id }
                }
                .onChange(of: history) { _, next in
                    rejectedPageIDs = nil
                    if waitingForPage {
                        sawLoading = sawLoading || next.isLoading
                        if !next.isLoading, sawLoading || next.error != nil || !next.hasMore {
                            waitingForPage = false
                            restoring = !state.followLive.isFollowing
                        }
                    }
                }
        }
    }

    /// Uses native List row virtualization with explicit document spacing and shared card views.
    /// The bounded scroll scope supplies the container identity independently of realized rows.
    private var feedList: some View {
        List {
            if showsHistoryHeader { historyHeaderRow }
            if emptyText != nil { emptyTextRow }
            ForEach(shown) { row in
                rowContent(row)
                    .modifier(ActivityFeedRowPlacement(
                        top: isDocumentFirst(row) ? PbRadius.Metrics.spacing12 : PbRadius.Metrics.spacing20,
                        bottom: PbRadius.Metrics.zero,
                        horizontalPadding: horizontalPadding
                    ))
            }
            if hasTailContent { tailRow }
            sentinelRow
        }
        .listStyle(.plain)
        .contentMargins(PbRadius.Metrics.zero, for: .scrollContent)
        // AppKit requires a positive default height; every explicit feed row exceeds this.
        .environment(\.defaultMinListRowHeight, PbRadius.Metrics.hairlineStroke)
        .scrollContentBackground(.hidden)
        .scrollChromeScope(onNativeScrollView: { identity in nativeIdentity.deliver(identity) })
        // Outside the scope's marker pair: in native-identity mode this observation view never
        // attaches to its own enclosingScrollView — an outer parallel lane is never a target.
        .background(ParallelScrollObserver(
            axis: .vertical, restorationOffset: targetOffset, restorationActive: restoring || followingLayout,
            onViewportSize: observeViewport, onUpwardIntent: upwardIntent, nativeIdentity: nativeIdentity
        ) { offset, content, viewport in
            if positioned, !restoring, !followingLayout, abs(content - position.content) < 0.5, position.viewport == viewport,
               abs(offset - position.offset) > 0.5 {
                pendingReadingCapture = true
                if offset < position.offset { shortFillBudget.replenish() }
            }
            if positioned, !restoring, !followingLayout, abs(content - position.content) < 0.5, position.viewport == viewport, offset < position.offset - 0.5 {
                state.followLive.observe(offset: offset, contentHeight: content, viewportHeight: viewport)
                if !state.followLive.isFollowing { targetOffset = nil }
            }
            if state.followLive.isFollowing, position.content != content || position.viewport != viewport { followingLayout = true }
            position.measurements.scheduleMeasurements()
            position.offset = offset
            position.content = content
            position.viewport = viewport
            // Native attachment can follow the first keyed task. Retry proxy positioning
            // once the native list has a usable viewport.
            let ready = viewport > 0
            if nativeViewportReady != ready { nativeViewportReady = ready }
            scheduleReadingUpdate()
        })
    }

    /// The feed's explicit document spacing on one List row, with the native contributions
    /// stripped: no row insets, separators, backgrounds or minimum height from the List itself,
    /// and the row's own horizontal padding plus top gap (12pt at the document edge, 20pt between
    /// actual children) live inside the row content. `ActivityRowGeometry` backgrounds the row
    /// BEFORE this padding, so measured frames stay the real row's document coordinates and
    /// exclude the inserted spacing.
    private struct ActivityFeedRowPlacement: ViewModifier {
        let top: CGFloat
        let bottom: CGFloat
        let horizontalPadding: CGFloat

        func body(content: Content) -> some View {
            content
                .padding(EdgeInsets(top: top, leading: horizontalPadding, bottom: bottom, trailing: horizontalPadding))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// The header is the document's first child whenever it shows — it owns the 12pt top edge.
    private var showsHistoryHeader: Bool {
        history.isLoading || waitingForPage || history.error != nil
            || (!history.hasMore && !rows.isEmpty
                && ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID) == 0)
    }

    @ViewBuilder private var historyHeaderRow: some View {
        if showsHistoryHeader {
            historyHeader
                .modifier(ActivityFeedRowPlacement(top: PbRadius.Metrics.spacing12, bottom: PbRadius.Metrics.zero,
                                                   horizontalPadding: horizontalPadding))
        }
    }

    @ViewBuilder private var emptyTextRow: some View {
        if let emptyText {
            Text(emptyText)
.font(.pb(.body))
.foregroundStyle(Color.secondaryText)
                .modifier(ActivityFeedRowPlacement(
                    top: showsHistoryHeader ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                    bottom: PbRadius.Metrics.zero,
                    horizontalPadding: horizontalPadding
                ))
        }
    }

    /// A row owns the 12pt top edge exactly when no header or empty text precedes it.
    private func isDocumentFirst(_ row: ActivityRow) -> Bool {
        !showsHistoryHeader && emptyText == nil && row.id == shown.first?.id
    }

    private func rowContent(_ row: ActivityRow) -> some View {
        rowView(row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ActivityRowGeometry(
                generation: measurementGeneration,
                measurements: position.measurements
            ) { [generation = measurementGeneration] frame in
                guard generation == measurementGeneration else { return }
                guard position.frames[row.id] != frame else { return }
                position.frames[row.id] = frame
                if row.id == shown.last?.id, realizedLastRowID != row.id { realizedLastRowID = row.id }
                scheduleReadingUpdate()
            })
            .pbFadeIn(animate: positioned && !restoring && state.followLive.isFollowing && !seenIDs.contains(row.id))
            .onAppear { seenIDs.insert(row.id) }
    }

    /// EmptyView contributes no row even when a caller supplies tail metadata for settlement.
    private var hasTailContent: Bool {
        Tail.self != EmptyView.self && tailValue != ActivityFeedTail()
    }

    private var hasContentBeforeTail: Bool {
        showsHistoryHeader || emptyText != nil || !shown.isEmpty
    }

    @ViewBuilder private var tailRow: some View {
        if hasTailContent {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing20) { tail() }
                .modifier(ActivityFeedRowPlacement(
                    top: hasContentBeforeTail ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                    bottom: PbRadius.Metrics.zero,
                    horizontalPadding: horizontalPadding
                ))
        }
    }

    /// The bottom sentinel keeps its own List row — outside the tail VStack — so live following
    /// has a stable scroll target past the tail, and the document's 12pt bottom edge rides on
    /// it.
    private var sentinelRow: some View {
        Color.clear
            .frame(height: PbRadius.Metrics.hairlineStroke)
            .modifier(ActivityFeedRowPlacement(
                top: (hasContentBeforeTail || hasTailContent) ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12,
                bottom: PbRadius.Metrics.spacing12,
                horizontalPadding: horizontalPadding
            ))
            .id(Self.bottomID)
    }

    @ViewBuilder private var historyHeader: some View {
        if history.isLoading || waitingForPage {
            LoadingLabel("Loading activity…")
        } else if let error = history.error {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                Text(error).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Button("Retry older activity") { requestPage(retry: true) }.buttonStyle(.link)
            }
        } else if !history.hasMore, ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID) == 0, !rows.isEmpty {
            Text("Beginning of activity").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private func rowView(_ row: ActivityRow) -> some View {
        switch row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: start, isExpanded: state.expandedGroups.contains(group.id)) {
                shortFillBudget.replenish()
                beginRestoration()
                withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                    if !state.expandedGroups.insert(group.id).inserted { state.expandedGroups.remove(group.id) }
                }
            }
        case .single(let row):
            switch row.kind {
            case .separator(let text): TurnSeparatorRow(text: text, timestamp: row.timestamp)
            case .item(let item): TimelineRow(model: TimelineRowModel(item: item, start: start, live: row.live, showsPromptBubble: showsPromptBubble))
            }
        }
    }

    private var currentWidthFrames: [String: CGRect] {
        guard let anchor = state.anchor, let measuredWidth = position.frames[anchor.id]?.width else { return position.frames }
        return position.frames.filter { abs($0.value.width - measuredWidth) < 1 }
    }

    private func captureAnchor() {
        guard pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil else { return }
        if let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
            viewportHeight: position.viewport, offset: position.offset) {
            state.anchor = anchor
            pendingReadingCapture = false
        }
    }

    private func observeViewport(_ size: CGSize) {
        guard size != viewportSize else { return }
        if positioned, !state.followLive.isFollowing {
            if viewportSize.width > 0, abs(size.width - viewportSize.width) > 0.5 {
                restorationRowWidth = max(0, size.width - 2 * horizontalPadding)
                let width = restorationRowWidth ?? 0
                position.frames = position.frames.filter { $0.key == state.anchor?.id || abs($0.value.width - width) < 1 }
            }
            beginRestoration()
        }
        if state.followLive.isFollowing { followingLayout = true }
        viewportSize = size
    }

    private func settle(_ proxy: ScrollViewProxy) async {
        await Task.yield()
        guard !Task.isCancelled, !isLoading, position.viewport > 0 else { return }
        if state.followLive.isFollowing {
            // Realize actual content before trusting the lazy document's estimated height.
            if !positioned, let last = shown.last, position.frames[last.id] == nil {
                targetOffset = nil
                proxy.scrollTo(last.id, anchor: .bottom)
                return // Its native measurement restarts this task through realizedLastRowID.
            }
            if !positioned || followingLayout {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            followingLayout = true
            targetOffset = max(0, position.content - position.viewport)
        } else if restoring {
            if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)) {
                let staleWidth = restorationRowWidth.map { abs((position.frames[id]?.width ?? -1) - $0) > 1 } ?? false
                if position.frames[id] == nil || staleWidth {
                    proxy.scrollTo(id, anchor: .top)
                    await Task.yield()
                }
            }
            restoreAnchor()
        }
        observePosition()
        scheduleReadingUpdate()
    }

    private func observePosition() {
        let timing = MonitorMetrics.begin()
        defer { MonitorMetrics.end(timing, stage: .activityViewport) }
        guard !isLoading, position.viewport > 0 else { return }
        finishRestoration()
        guard positioned, !restoring, !followingLayout else { return }
        if let restorationTiming {
            MonitorMetrics.end(restorationTiming, stage: .activityScrollRestore)
            self.restorationTiming = nil
        }
        state.scrollOffset = position.offset
        captureAnchor()
        let wasFollowing = state.followLive.isFollowing
        if !shown.isEmpty {
            state.followLive.observe(offset: position.offset, contentHeight: position.content, viewportHeight: position.viewport)
        }
        if wasFollowing, !state.followLive.isFollowing, state.retainedFirstID == nil {
            state.retainedFirstID = shown.first?.id
        }
    }

    private func scheduleReadingUpdate() {
        position.pagingTask?.cancel()
        position.pagingTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            if restoring { restoreAnchor() }
            observePosition()
            guard positioned, !restoring, !followingLayout else { return }
            if !shown.isEmpty {
                guard let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
                    viewportHeight: position.viewport, offset: position.offset) else { return }
                if pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil {
                    state.anchor = anchor
                    pendingReadingCapture = false
                }
            }
            maybeLoadOlder()
        }
    }

    private func finishRestoration() {
        defer {
            state.viewportPositioned = positioned && !restoring && !followingLayout
        }
        if !state.followLive.isFollowing { followingLayout = false }
        if state.followLive.isFollowing, followingLayout {
            if !positioned, let last = shown.last, position.frames[last.id] == nil { return }
            targetOffset = max(0, position.content - position.viewport)
            if abs(position.offset - (targetOffset ?? 0)) < 1 {
                followingLayout = false
                positioned = true
                restoring = false
            } else { return }
        }
        if restoring {
            if state.followLive.isFollowing,
               abs(position.offset - max(0, position.content - position.viewport)) < 2 {
                positioned = true; restoring = false
            } else if let targetOffset,
                      abs(position.offset - min(max(0, targetOffset), max(0, position.content - position.viewport))) < 1 {
                positioned = true; restoring = false
                restorationRowWidth = nil
            }
        }
    }

    private func beginRestoration() {
        restorationTiming = MonitorMetrics.begin()
        state.followLive.suspend()
        pendingReadingCapture = false
        position.pagingTask?.cancel()
        measurementGeneration &+= 1
        position.frames.removeAll(keepingCapacity: true)
        position.measurements.invalidateMeasurements()
        restoring = true
        state.viewportPositioned = false
        targetOffset = nil
    }

    private func restoreAnchor() {
        guard !state.followLive.isFollowing else { return }
        if shown.isEmpty {
            state.anchor = nil
            state.retainedFirstID = nil
            position.frames.removeAll()
            restorationRowWidth = nil
            targetOffset = 0
        } else if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)), let frame = position.frames[id] {
            if let restorationRowWidth, abs(frame.width - restorationRowWidth) > 1 { return }
            targetOffset = anchor.offset(in: frame)
        } else if state.anchor == nil { targetOffset = state.scrollOffset }
        finishRestoration()
    }

    private var upwardIntent: (() -> Void)? {
        isVisible ? {
            pauseLayoutFollowingForUserIntent()
            replenishShortFill()
        } : nil
    }

    private func pauseLayoutFollowingForUserIntent() {
        guard positioned, !restoring, followingLayout, state.followLive.isFollowing else { return }
        state.followLive.suspend()
        followingLayout = false
        if state.retainedFirstID == nil { state.retainedFirstID = shown.first?.id }
        targetOffset = nil
        pendingReadingCapture = true
    }

    private func replenishShortFill() {
        guard isVisible, positioned, !restoring, !waitingForPage, !history.isLoading else { return }
        shortFillBudget.replenish()
        rejectedPageIDs = nil
        if position.content <= position.viewport + 1 { scheduleReadingUpdate() }
    }

    private func maybeLoadOlder() {
        guard rejectedPageIDs != ids, !waitingForPage, ActivityFeedWindow.shouldLoad(offset: position.offset, viewport: position.viewport,
            eligibility: ActivityFeedEligibility(positioned: positioned, restoring: restoring, visible: isVisible,
                loading: history.isLoading, error: history.error)) else { return }
        let boundary = ActivityFeedWindow.olderBoundary(ids: ids, retainedID: state.retainedFirstID)
        guard boundary != nil || history.hasMore,
              shortFillBudget.consume(content: position.content, viewport: position.viewport) else { return }
        if let boundary {
            beginRestoration()
            state.retainedFirstID = boundary
        } else if history.hasMore { requestPage(retry: false) }
    }

    private func requestPage(retry: Bool) {
        let timing = MonitorMetrics.begin()
        defer { MonitorMetrics.end(timing, stage: .activityPaginationRequest) }
        guard isVisible, !waitingForPage, !history.isLoading, let onLoadMore,
              retry || history.error == nil else { return }
        if retry { rejectedPageIDs = nil }
        requestedIDs = ids
        waitingForPage = true
        sawLoading = false
        guard onLoadMore() else {
            rejectedPageIDs = ids
            waitingForPage = false
            requestedIDs = []
            return
        }
        beginRestoration()
    }

    private func preserveRegroupedAnchor(old: [ActivityRow], next: [ActivityRow]) {
        guard let anchor = state.anchor, !next.contains(where: { $0.id == anchor.id }),
              let oldRow = old.first(where: { $0.id == anchor.id }) else { return }
        let members: Set<String> = switch oldRow {
        case .single(let row): [row.id]
        case .toolGroup(let group): Set(group.members.map(\.id))
        }
        if let index = next.firstIndex(where: { row in
            switch row {
            case .single(let value): !members.isDisjoint(with: [value.id])
            case .toolGroup(let group): group.members.contains { members.contains($0.id) }
            }
        }) {
            let replacement = next[index].id
            state.anchor = ParallelVerticalAnchor(id: replacement, index: index, relativeOffset: anchor.relativeOffset)
            if state.retainedFirstID == anchor.id { state.retainedFirstID = replacement }
            if state.expandedGroups.remove(anchor.id) != nil { state.expandedGroups.insert(replacement) }
        }
    }
}

#if DEBUG
/// Overflowing dummy rows prove the feed's thin chrome and content fit together — no invented
/// production values, only `PreviewFixtures`' own fixture items.
@MainActor
private func activityFeedPreview() -> some View {
    let rows = ActivityRowsBuilder.build(from: PreviewFixtures.sampleRows(taskID: "feed-preview", running: false))
    let liveStep = LiveStep(rows: [], isRunning: true)
    return ActivityFeedView(rows: rows, start: .now.addingTimeInterval(-600), history: EventHistoryState(),
                            isLoading: false, tailValue: ActivityFeedTail(liveStep: liveStep), emptyText: nil,
                            state: ParallelColumnUIState(), onLoadMore: nil) {
        LiveStepLineView(text: "Running the login tests…", indicator: .threeDots)
    }
    .frame(width: PbRadius.Metrics.timelinePanePreviewWidth, height: PbRadius.Metrics.taskDetailPreviewHeight)
    .background(Color.windowBG)
}

#Preview("ActivityFeed - light") { activityFeedPreview().preferredColorScheme(.light) }
#Preview("ActivityFeed - dark") { activityFeedPreview().preferredColorScheme(.dark) }
#endif
