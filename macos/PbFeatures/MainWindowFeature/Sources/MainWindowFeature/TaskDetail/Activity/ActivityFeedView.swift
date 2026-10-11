import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedKey

private struct ActivityFeedKey: Equatable {
    let nativeViewportReady: Bool
    let realizedLastRowID: String?
    let rows: [ActivityRow]
    let tail: ActivityFeedTail
    let tailPresentation: ActivityFeedTailPresentation
    let showsPromptBubble: Bool
    let expandedGroups: Set<String>
    let viewport: CGSize
    let history: EventHistoryState
    let loading: Bool
    let visible: Bool
    let paginationRevision: Int
    let restoring: Bool
}

// MARK: - ActivityFeedView

/// Shared reading, progressive reveal and older-page behavior across activity surfaces.
struct ActivityFeedView: View {
    let rows: [ActivityRow]
    let start: Date?
    let history: EventHistoryState
    let isLoading: Bool
    var tailValue = ActivityFeedTail()
    var paginationRevision = 0
    var isVisible = true
    var emptyText: String?
    var horizontalPadding: CGFloat = PbRadius.Metrics.zero
    var showsPromptBubble = true
    let state: ParallelColumnUIState
    let onLoadMore: (() -> Bool)?
    var tailPresentation = ActivityFeedTailPresentation.absent
    var onSelectChildTask: ((String) -> Void)?

    @State private var tailStore: ActivityFeedTailStore
    @State private var measurementGeneration = 0
    @State private var viewportSize: CGSize = .zero
    @State private var nativeViewportReady = false
    @State private var realizedLastRowID: String?
    @State private var position = ActivityFeedPosition()
    @State private var listCallbacks = ActivityFeedListCallbacks()
    @State private var nativeIdentity = ParallelScrollNativeIdentity()
    @State private var positioned = false
    @State private var followingLayout = true
    @State private var restoring = true
    @State private var targetOffset: CGFloat?
    @State private var restorationWidth = ActivityRowWidthRestoration()
    @State private var restorationTiming: UInt64?
    @State private var shortFillBudget = ActivityShortFillBudget()
    @State private var waitingForPage = false
    @State private var requestedIDs: [String] = []
    @State private var rejectedPageIDs: [String]?
    @State private var sawLoading = false
    @State private var seenIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(rows: [ActivityRow], start: Date?, history: EventHistoryState, isLoading: Bool,
         tailValue: ActivityFeedTail = ActivityFeedTail(), paginationRevision: Int = 0, isVisible: Bool = true,
         emptyText: String? = nil, horizontalPadding: CGFloat = PbRadius.Metrics.zero, showsPromptBubble: Bool = true,
         state: ParallelColumnUIState, onLoadMore: (() -> Bool)?,
         tailPresentation: ActivityFeedTailPresentation = .absent, onSelectChildTask: ((String) -> Void)? = nil) {
        self.rows = rows
        self.start = start
        self.history = history
        self.isLoading = isLoading
        self.tailValue = tailValue
        self.paginationRevision = paginationRevision
        self.isVisible = isVisible
        self.emptyText = emptyText
        self.horizontalPadding = horizontalPadding
        self.showsPromptBubble = showsPromptBubble
        self.state = state
        self.onLoadMore = onLoadMore
        self.tailPresentation = tailPresentation
        self.onSelectChildTask = onSelectChildTask
        _tailStore = State(initialValue: ActivityFeedTailStore(presentation: tailPresentation.isVisible(with: tailValue) ? tailPresentation : .absent))
    }

    private static var bottomID: String { "activity-feed-bottom" }
    private var ids: [String] { rows.map(\.id) }
    private var shown: [ActivityRow] {
        Array(rows.dropFirst(ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID)))
    }

    var body: some View {
        let shownRows = shown
        refreshListCallbacks()
        return ScrollViewReader { proxy in
            feedList(shownRows: shownRows)
                .task(id: ActivityFeedKey(nativeViewportReady: nativeViewportReady, realizedLastRowID: realizedLastRowID,
                                         rows: shownRows, tail: tailValue, tailPresentation: tailPresentation, showsPromptBubble: showsPromptBubble,
                                         expandedGroups: state.expandedGroups, viewport: viewportSize, history: history,
                                         loading: isLoading, visible: isVisible, paginationRevision: paginationRevision, restoring: restoring)) {
                    await settle(proxy)
                }
                .onAppear {
                    refreshListCallbacks()
                    tailStore.presentation = effectiveTailPresentation
                    position.measurements.invalidateMeasurements()
                    position.measurements.scheduleMeasurements()
                }
                .onDisappear {
                    position.pagingTask?.cancel()
                    position.pagingTask = nil
                    listCallbacks.clearActions()
                }
                .onChange(of: rows) { old, next in
                    defer { bindIntendedListSnapshot() }
                    if state.followLive.isFollowing { followingLayout = true }
                    preserveRegroupedAnchor(old: old, next: next)
                    if !state.followLive.isFollowing { beginRestoration() }
                    if waitingForPage, requestedIDs != ids {
                        state.retainedFirstID = next.first?.id
                        waitingForPage = false
                    }
                    markReferencePagePublication()
                }
                .onChange(of: effectiveTailPresentation) { old, next in
                    defer { bindIntendedListSnapshot() }
                    if state.followLive.isFollowing { followingLayout = true }
                    else if (old != .absent) != (next != .absent) { beginRestoration() }
                    tailStore.presentation = next
                }
                .onChange(of: tailValue) { _, _ in
                    defer { bindIntendedListSnapshot() }
                    if state.followLive.isFollowing { followingLayout = true }
                    markReferencePagePublication()
                }
                .onChange(of: paginationRevision) { _, _ in
                    defer { bindIntendedListSnapshot() }
                    rejectedPageIDs = nil
                    waitingForPage = false
                    sawLoading = false
                    if !state.followLive.isFollowing { beginRestoration() }
                    if !rows.isEmpty { state.retainedFirstID = rows.first?.id }
                    markReferencePagePublication()
                }
                .onChange(of: history) { _, next in historyChanged(next) }
        }
    }

    private func feedList(shownRows: [ActivityRow]) -> some View {
        let snapshot = ActivityFeedListSnapshot(generation: measurementGeneration, shownIDs: shownRows.map(\.id),
                                               showsHistoryHeader: showsHistoryHeader, showsEmptyText: emptyText != nil,
                                               hasTailContent: hasTailContent, anchor: state.anchor)
        position.registerListSnapshotCandidate(generation: snapshot.generation, expectedCount: snapshot.expectedCount,
                                               expectedAnchorIndex: snapshot.anchorIndex, expectedPadding: snapshot.expectedPadding)
        return listContent(shownRows: shownRows)
.equatable()
        // Outside the marker pair; native identity excludes the outer parallel lane.
        .background(ParallelScrollObserver(
            axis: .vertical, restorationOffset: targetOffset, restorationActive: restoring || followingLayout,
            onNativeViewportGeometry: observeViewport, onUpwardIntent: upwardIntent, nativeIdentity: nativeIdentity,
            anchorProvider: position.referenceRestoration
        ) { offset, content, viewport in
            let unchangedGeometry = abs(content - position.content) < 0.5 && position.viewport == viewport
            let movedUp = offset < position.offset - 0.5
            let movedDown = offset > position.offset + 0.5
            if positioned, !restoring, !followingLayout, abs(content - position.content) < 0.5, position.viewport == viewport,
               abs(offset - position.offset) > 0.5 {
                position.pendingReadingCapture = true
                if movedUp, !state.followLive.isFollowing { targetOffset = nil }
                if offset < position.offset { shortFillBudget.replenish() }
            }
            if positioned, !restoring, !followingLayout, unchangedGeometry, position.referenceRestoration?.isActive != true,
               state.followLive.isFollowing ? movedUp : movedDown {
                let wasFollowing = state.followLive.isFollowing
                state.followLive.observe(offset: offset, contentHeight: content, viewportHeight: viewport)
                if !state.followLive.isFollowing { targetOffset = nil }
                if wasFollowing, state.followLive.isFollowing, max(0, content - viewport) - offset > 1 {
                    followingLayout = true
                }
            }
            if state.followLive.isFollowing, position.content != content || position.viewport != viewport { followingLayout = true }
            position.measurements.scheduleMeasurements()
            position.offset = offset
            position.content = content
            position.viewport = viewport
            if positioned, !restoring, !followingLayout, !state.followLive.isFollowing, unchangedGeometry, movedUp,
               position.pendingReadingCapture, position.referenceRestoration?.isActive != true,
               position.referenceRestoration?.cancelled != true,
               let anchor = position.captureNativeReadingAnchor(shownIDs: shown.map(\.id), nativeIdentity: nativeIdentity) {
                state.anchor = anchor
                state.scrollOffset = offset
                position.pendingReadingCapture = false
            }
            reconcileReferenceRestoration()
            // Retry initial positioning when native attachment becomes usable.
            let ready = viewport > 0
            if nativeViewportReady != ready { nativeViewportReady = ready }
            scheduleReadingUpdate()
        })
    }

    private func refreshListCallbacks() {
        let position = position
        let nativeIdentity = nativeIdentity
        listCallbacks.onNativeIdentity = { identity in
            position.adoptViewportIdentity(identity)
            if nativeIdentity.deliver(identity) {
                position.discardStaleFrames(nativeIdentity: nativeIdentity)
                position.measurements.invalidateMeasurements()
            }
        }
        listCallbacks.onFrame = { id, generation, sample in
            guard generation == measurementGeneration else { return }
            guard position.record(sample, for: id, nativeIdentity: nativeIdentity) else { return }
            if id == shown.last?.id, realizedLastRowID != id { realizedLastRowID = id }
            scheduleReadingUpdate()
        }
        listCallbacks.onAppear = { seenIDs.insert($0) }
        listCallbacks.onRetry = { requestPage(retry: true) }
        listCallbacks.onDisclosure = { id in
            defer { bindIntendedListSnapshot() }
            shortFillBudget.replenish()
            beginRestoration(cause: .disclosure)
            withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                if !state.expandedGroups.insert(id).inserted { state.expandedGroups.remove(id) }
            }
        }
        listCallbacks.onSelectChildTask = onSelectChildTask
    }

    private func listContent(shownRows: [ActivityRow]) -> ActivityFeedListContent {
        let header: ActivityFeedListRenderInputs.Header = if history.isLoading || waitingForPage { .loading }
        else if let error = history.error { .error(error) }
        else if showsHistoryHeader { .beginning }
        else { .none }
        let fadeIDs = positioned && !restoring && state.followLive.isFollowing
            ? Set(shownRows.map(\.id)).subtracting(seenIDs) : []
        return ActivityFeedListContent(inputs: ActivityFeedListRenderInputs(
            rows: shownRows, start: start, header: header, emptyText: emptyText, horizontalPadding: horizontalPadding,
            showsPromptBubble: showsPromptBubble, expandedGroups: state.expandedGroups,
            generation: measurementGeneration, fadeIDs: fadeIDs,
            hasTail: hasTailContent
        ), callbacks: listCallbacks, measurements: position.measurements, tailStore: tailStore)
    }

    private var showsHistoryHeader: Bool {
        history.isLoading || waitingForPage || history.error != nil
            || (!history.hasMore && !rows.isEmpty
                && ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID) == 0)
    }

    private var intendedListSnapshot: ActivityFeedListSnapshot {
        ActivityFeedListSnapshot(generation: measurementGeneration, shownIDs: shown.map(\.id),
                                 showsHistoryHeader: showsHistoryHeader, showsEmptyText: emptyText != nil,
                                 hasTailContent: hasTailContent, anchor: state.anchor)
    }

    private func bindIntendedListSnapshot() {
        position.bindListSnapshot(intendedListSnapshot, nativeIdentity: nativeIdentity)
    }

    private var hasTailContent: Bool { tailPresentation.isVisible(with: tailValue) }
    private var effectiveTailPresentation: ActivityFeedTailPresentation { hasTailContent ? tailPresentation : .absent }

    private var currentWidthFrames: [String: CGRect] {
        position.discardStaleFrames(nativeIdentity: nativeIdentity)
        guard let anchor = state.anchor, let measuredWidth = position.frames[anchor.id]?.width else { return position.frames }
        return position.frames.filter { abs($0.value.width - measuredWidth) < 1 }
    }

    @discardableResult
    private func captureAnchor() -> Bool {
        guard !(position.referenceRestoration?.cancelled == true && position.referenceRestoration?.pagePending == true) else { return false }
        guard position.pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil else { return false }
        guard let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
            viewportHeight: position.viewport, offset: position.offset) else { return false }
        state.anchor = anchor
        position.pendingReadingCapture = false
        return true
    }

    private func observeViewport(_ size: CGSize, outerWidth: CGFloat) {
        let previousSize = position.nativeViewportSize
        let outerWidthChanged = position.nativeOuterWidth.map { abs(outerWidth - $0) > 0.5 } ?? false
        position.nativeViewportSize = size
        position.nativeOuterWidth = outerWidth
        defer { bindIntendedListSnapshot() }
        guard size != previousSize || outerWidthChanged else { return }
        let needsMeasuredResize = outerWidthChanged || abs(size.height - previousSize.height) > 0.5
        let clipWidthChanged = previousSize.width > 0 && abs(size.width - previousSize.width) > 0.5
        if positioned, !state.followLive.isFollowing {
            if !needsMeasuredResize, clipWidthChanged, !position.pendingReadingCapture, let anchor = state.anchor,
               position.referenceRestoration?.isActive != true, position.referenceRestoration?.cancelled != true {
                let pagePending = waitingForPage || position.referenceRestoration?.pagePending == true
                position.openReferenceRestoration(anchor: anchor, shownIDs: shown.map(\.id),
                                                  nativeIdentity: nativeIdentity, generation: measurementGeneration,
                                                  awaitingPagePublication: pagePending)
                restoring = true
                position.pendingReadingCapture = false
                targetOffset = nil
                state.viewportPositioned = false
            }
            if clipWidthChanged {
                restorationWidth.resize(
                    measuredWidth: position.expectedRowWidth(
                        for: state.anchor?.id, viewportWidth: size.width, nativeIdentity: nativeIdentity
                    ),
                    previousViewportWidth: previousSize.width, viewportWidth: size.width, restoring: restoring
                )
            }
            // Legacy scroller appearance changes only clip width; keep the native lease
            // eligible while updating row-width acceptance from the actual clip geometry.
            if needsMeasuredResize { beginRestoration(cause: .resize) }
        }
        if state.followLive.isFollowing, size != previousSize { followingLayout = true }
        viewportSize = size
    }

    private func settle(_ proxy: ScrollViewProxy) async {
        await Task.yield()
        reconcileReferenceRestoration()
        position.discardStaleFrames(nativeIdentity: nativeIdentity)
        guard !Task.isCancelled, !isLoading, position.viewport > 0 else { return }
        if state.followLive.isFollowing {
            if !positioned, let last = shown.last, position.frames[last.id] == nil {
                targetOffset = nil
                proxy.scrollTo(last.id, anchor: .bottom)
                return // Its native measurement restarts this task through realizedLastRowID.
            }
            if !positioned || followingLayout {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                await Task.yield()
                guard !Task.isCancelled, state.followLive.isFollowing else { return }
            }
            followingLayout = true
            targetOffset = max(0, position.content - position.viewport)
        } else if restoring {
            if let transaction = position.referenceRestoration, transaction.isActive, transaction.appliedTarget != nil {
                // Fresh native correction owns the target over proxy and stale numeric paths.
            } else if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)) {
                let staleWidth = !restorationWidth.accepts(rowWidth: position.frames[id]?.width)
                if position.frames[id] == nil || staleWidth {
                    // Missing or unrealized anchor: the proxy fallback still restores it.
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
        if wasFollowing, !shown.isEmpty {
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
            reconcileReferenceRestoration()
            if restoring { restoreAnchor() }
            observePosition()
            guard positioned, !restoring, !followingLayout else { return }
            guard !(position.referenceRestoration?.cancelled == true && position.referenceRestoration?.pagePending == true) else { return }
            if !shown.isEmpty {
                guard let anchor = ParallelVerticalAnchor.capture(ids: shown.map(\.id), frames: currentWidthFrames,
                    viewportHeight: position.viewport, offset: position.offset) else { return }
                if position.pendingReadingCapture || state.followLive.isFollowing || state.anchor == nil {
                    state.anchor = anchor
                    position.pendingReadingCapture = false
                }
            }
            maybeLoadOlder()
        }
    }

    private func historyChanged(_ next: EventHistoryState) {
        defer { bindIntendedListSnapshot() }
        rejectedPageIDs = nil
        if waitingForPage {
            sawLoading = sawLoading || next.isLoading
            if !next.isLoading, sawLoading || next.error != nil || !next.hasMore {
                waitingForPage = false
                restoring = !state.followLive.isFollowing && position.referenceRestoration?.cancelled != true
                restorationWidth.finish(restoring: restoring)
            }
        }
        markReferencePagePublication()
    }
}

// MARK: - ActivityFeedView restoration

private extension ActivityFeedView {
    private func restoreAnchor() {
        reconcileReferenceRestoration()
        position.discardStaleFrames(nativeIdentity: nativeIdentity)
        guard !state.followLive.isFollowing else { return }
        if shown.isEmpty {
            state.anchor = nil
            state.retainedFirstID = nil
            position.clearFrames()
            restorationWidth.clear()
            position.referenceRestoration?.finish()
            nativeIdentity.setAnchorProvider(nil)
            position.referenceRestoration = nil
            targetOffset = 0
        } else if let transaction = position.referenceRestoration, transaction.isActive,
                  let applied = transaction.appliedTarget {
            targetOffset = applied
        } else if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)), let frame = position.frames[id] {
            guard restorationWidth.accepts(rowWidth: frame.width) else { return }
            // Same-document pre-change frames are stale unless their sample pair matches.
            guard sampledPairMatchesCurrentDocument(id) else { return }
            targetOffset = anchor.offset(in: frame)
        } else if state.anchor == nil { targetOffset = state.scrollOffset }
        finishRestoration()
    }

    private func sampledPairMatchesCurrentDocument(_ id: String) -> Bool {
        guard position.referenceRestoration?.isActive == true else { return true }
        return position.sampledPairs[id] == position.currentDocumentPair()
    }

    private func reconcileReferenceRestoration() {
        guard let transaction = position.referenceRestoration else { return }
        guard transaction.cancelled || transaction.finished else { return }
        if transaction.finished { nativeIdentity.setAnchorProvider(nil); position.referenceRestoration = nil; return }
        guard transaction.cancelled else { return }
        if !transaction.cancellationReconciled {
            transaction.cancellationReconciled = true
            targetOffset = nil
            position.pagingTask?.cancel()
            position.pagingTask = nil
            restoring = false
            restorationWidth.finish(restoring: false)
            position.pendingReadingCapture = true
        }
        state.scrollOffset = position.offset
        state.anchor = position.captureNativeReadingAnchor(shownIDs: shown.map(\.id), nativeIdentity: nativeIdentity)
        if transaction.pagePending, state.anchor != nil {
            // Hand off a new token synchronously, without invalidating measurements.
            position.openReferenceRestoration(anchor: state.anchor, shownIDs: shown.map(\.id),
                                              nativeIdentity: nativeIdentity, generation: measurementGeneration,
                                              awaitingPagePublication: true)
            position.pendingReadingCapture = false
            restoring = true
            bindIntendedListSnapshot()
        } else if transaction.pageCommitted {
            nativeIdentity.setAnchorProvider(nil)
            position.referenceRestoration = nil
        }
        state.viewportPositioned = positioned && !restoring && !followingLayout
    }

    private func markReferencePagePublication() {
        guard let transaction = position.referenceRestoration, transaction.pagePending else { return }
        guard !waitingForPage, !history.isLoading else { return }
        transaction.markPageCommitted()
        if transaction.cancelled {
            nativeIdentity.setAnchorProvider(nil)
            position.referenceRestoration = nil
        }
    }

    private func finishRestoration() {
        position.discardStaleFrames(nativeIdentity: nativeIdentity)
        defer {
            restorationWidth.finish(restoring: restoring)
            state.viewportPositioned = positioned && !restoring && !followingLayout
        }
        if !state.followLive.isFollowing { followingLayout = false }
        if state.followLive.isFollowing, followingLayout {
            position.referenceRestoration?.cancelAnchorRestoration()
            position.referenceRestoration = nil
            nativeIdentity.setAnchorProvider(nil)
            if !positioned, let last = shown.last, position.frames[last.id] == nil { return }
            targetOffset = max(0, position.content - position.viewport)
            if abs(position.offset - (targetOffset ?? 0)) < 1 {
                followingLayout = false
                positioned = true
                restoring = false
            } else { return }
        }
        if restoring {
            if let transaction = position.referenceRestoration, transaction.isActive {
                finishReferenceRestoration(transaction)
            } else if state.followLive.isFollowing,
                      abs(position.offset - max(0, position.content - position.viewport)) < 2 {
                positioned = true; restoring = false
            } else if let targetOffset,
                      abs(position.offset - min(max(0, targetOffset), max(0, position.content - position.viewport))) < 1 {
                positioned = true; restoring = false
            }
        }
    }

    private func finishReferenceRestoration(_ transaction: ActivityFeedReferenceRestoration) {
        guard transaction.pageCommitted, transaction.matchesCurrentCandidate(document: position.pairedDocument) else { return }
        let maxTarget = max(0, position.content - position.viewport)
        if let applied = transaction.appliedTarget {
            guard position.currentDocumentPair() == transaction.appliedDocumentPair else { return }
            guard abs(position.offset - min(applied, maxTarget)) < 1 else { return }
            transaction.finish()
            nativeIdentity.setAnchorProvider(nil)
            position.referenceRestoration = nil
            positioned = true
            restoring = false
            targetOffset = applied
        } else if let targetOffset,
                  abs(position.offset - min(max(0, targetOffset), maxTarget)) < 1 {
            if let anchor = state.anchor, let id = anchor.resolvedID(in: shown.map(\.id)) {
                guard let frame = position.frames[id], restorationWidth.accepts(rowWidth: frame.width),
                      sampledPairMatchesCurrentDocument(id) else { return }
            }
            transaction.finish()
            nativeIdentity.setAnchorProvider(nil)
            position.referenceRestoration = nil
            positioned = true
            restoring = false
        }
    }

    private enum RestorationCause {
        case publication, pageRequest, retainedReveal, resize, disclosure
    }

    private func beginRestoration(cause: RestorationCause = .publication) {
        reconcileReferenceRestoration()
        var inheritedPagePending = false
        if let transaction = position.referenceRestoration, transaction.cancelled {
            // Only an explicit opening replaces the cancelled token with a live anchor.
            guard cause != .publication else { return }
            inheritedPagePending = transaction.pagePending
            state.scrollOffset = position.offset
            state.anchor = position.captureNativeReadingAnchor(shownIDs: shown.map(\.id), nativeIdentity: nativeIdentity)
            position.referenceRestoration = nil
        }
        restorationTiming = MonitorMetrics.begin()
        state.followLive.suspend()
        position.pendingReadingCapture = false
        position.pagingTask?.cancel()
        measurementGeneration &+= 1
        if let transaction = position.referenceRestoration, transaction.isActive {
            if let id = state.anchor?.resolvedID(in: shown.map(\.id)), let oldID = transaction.stableID, id != oldID {
                // An explicitly replaced anchor opens a fresh lease; unrealized targets use fallback.
                transaction.cancelAnchorRestoration()
                position.openReferenceRestoration(anchor: state.anchor, shownIDs: shown.map(\.id),
                                                  nativeIdentity: nativeIdentity, generation: measurementGeneration,
                                                  awaitingPagePublication: transaction.pagePending)
            } else { transaction.join(generation: measurementGeneration) }
        } else if cause != .publication {
            position.openReferenceRestoration(anchor: state.anchor, shownIDs: shown.map(\.id),
                                              nativeIdentity: nativeIdentity, generation: measurementGeneration,
                                              awaitingPagePublication: cause == .pageRequest || inheritedPagePending)
        }
        if cause == .resize { position.referenceRestoration?.deferToMeasuredResize() }
        position.clearFrames()
        position.measurements.invalidateMeasurements()
        restoring = true
        state.viewportPositioned = false
        targetOffset = nil
    }

    private var upwardIntent: (() -> Void)? {
        isVisible ? {
            pauseLayoutFollowingForUserIntent()
            replenishShortFill()
        } : nil
    }

    private func pauseLayoutFollowingForUserIntent() {
        guard positioned, !restoring, state.followLive.isFollowing else { return }
        state.followLive.suspend()
        followingLayout = false
        if state.retainedFirstID == nil { state.retainedFirstID = shown.first?.id }
        targetOffset = nil
        position.pendingReadingCapture = true
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
            beginRestoration(cause: .retainedReveal)
            state.retainedFirstID = boundary
            bindIntendedListSnapshot()
        } else if history.hasMore { requestPage(retry: false) }
    }

    private func requestPage(retry: Bool) {
        defer { bindIntendedListSnapshot() }
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
        beginRestoration(cause: .pageRequest)
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
