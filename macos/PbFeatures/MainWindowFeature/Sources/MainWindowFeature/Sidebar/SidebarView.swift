//
//  SidebarView.swift
//  MainWindowFeature
//
//  The redesigned sidebar (Monitor redesign Phase 1, SPEC §6.1): a fixed New session button (the
//  old toolbar "+" action) above the search field and the compact backend-dot filter, the Running /
//  Today / Earlier list (whole trees and parallel groups, settled plan D10), history diagnostics
//  with a manual Load older control while more pages exist, and a connection footer. Search is
//  trimmed, lowercased and case-insensitive over title/ID/repo; the backend filter composes with
//  lineage retention. `SettingsLink` stays.
//

import MonitorCore
import PbCommon
import PbRepository
import PbUI
import SwiftUI

// MARK: - SidebarViewModel

/// View model protocol for the Sidebar screen.
@MainActor
protocol SidebarViewModel: ViewModel {
    
    /// Running / Today / Earlier, in that order, empty buckets omitted (settled plan D10).
    var sections: [SidebarSection] { get }
    var taskHistoryState: HistoryLoadingState { get }
    var workflowHistoryState: HistoryLoadingState { get }
    var historyPresentationRevision: Int { get }
    func didChangeHistoryBottomVisibility(_ visible: Bool, revision: Int)
    func didTapLoadMoreTasks()
    func didTapLoadMoreWorkflows()
    var listErrorMessage: String? { get }
    /// The list body's empty-state message, or `nil` when there's real content to show (Monitor
    /// piece 6's precedence rules — see `SidebarVM.computeEmptyStateMessage()`).
    var emptyStateMessage: String? { get }
    /// A shimmer placeholder instead of an empty list (Monitor piece 11, Plan review round 1 item
    /// 4): true only before the first listing arrives (`hasListed == false`) with no error and no
    /// install banner already occupying the space — see `SidebarVM.recompute()`.
    var showsLoadingSkeleton: Bool { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var backendTabs: [BackendTab] { get }
    var selectedBackend: String { get }
    var catalogUnavailableNote: String? { get }
    var searchQuery: String { get }
    var selection: MonitorDestination? { get }
    /// The install/update banner, or `nil` when nothing needs surfacing — shown in place of the
    /// red error section (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }
    var savedWorkflows: [WorkflowRecord] { get }
    var workflowErrorMessage: String? { get }
    func didTapNewWorkflow()
    func groupConversations(_ group: ParallelGroup) -> [Conversation]
    func isExecutionParentExpanded(_ id: String) -> Bool

    func didAppear()
    func didDisappear()
    func didChangeSearchQuery(_ text: String)
    func didSelectBackendFilter(_ backend: String)
    func didSelect(_ destination: MonitorDestination?)
    func didTapNewSession()
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()

    // MARK: Collapsible tree (settled plan, Monitor piece 4)

    func didToggleExpansion(taskID: String)
    /// ← collapses the selected row (or moves to its parent); → expands it — see `SidebarVM`.
    func didPressMoveCommand(_ direction: MoveCommandDirection)
}

extension SidebarViewModel {
    var savedWorkflows: [WorkflowRecord] { [] }
    var workflowErrorMessage: String? { nil }
    func didTapNewWorkflow() {}
    func groupConversations(_ group: ParallelGroup) -> [Conversation] { group.conversations }
    func isExecutionParentExpanded(_ id: String) -> Bool { false }
}

extension SidebarViewModel {
    var taskHistoryState: HistoryLoadingState { HistoryLoadingState() }
    var workflowHistoryState: HistoryLoadingState { HistoryLoadingState() }
    var historyPresentationRevision: Int { 0 }
    func didChangeHistoryBottomVisibility(_: Bool, revision _: Int) {}
    func didTapLoadMoreTasks() {}
    func didTapLoadMoreWorkflows() {}
}

// MARK: - SidebarView

struct SidebarView<VM: SidebarViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.defaultMinListRowHeight) private var minimumRowHeight
    @State private var seenRowIDs: Set<String> = []
    @State private var displayedSections: [SidebarSection]?
    @State private var fadingRowIDs: Set<String> = []
    @State private var disclosureTask: Task<Void, Never>?
    @State private var workflowsExpanded = true
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        list
            // Let the native sidebar List own the titlebar safe area. A surrounding VStack
            // can be extended underneath the unified toolbar when leaving full screen.
            .safeAreaInset(edge: .top, spacing: PbRadius.Metrics.zero) {
                header.background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: PbRadius.Metrics.zero) { footer.background(.bar) }
        // New session moved from the toolbar into the column itself (SPEC §6.1): the same
        // `didTapNewSession` action, now a fixed full-width button above the search field — never
        // a scrollable List row. The window controls and the sidebar toggle stay system-owned.
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Private Views

    /// The fixed controls above the list: the full-width New session button, then the search field
    /// beside the compact backend-dot filter, then the degraded-catalog note when there is one.
    private var header: some View {
        VStack(spacing: PbRadius.Metrics.spacing8) {
            newSessionButton
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    searchField.frame(minWidth: PbRadius.Metrics.sidebarSearchMinimumWidth)
                    backendFilterMenu.fixedSize()
                }
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                    searchField
                    backendFilterMenu
                }
            }
            if let note = viewModel.catalogUnavailableNote {
                Text(note)
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, PbRadius.Metrics.spacing16)
        .padding(.top, PbRadius.Metrics.spacing12)
        .padding(.bottom, PbRadius.Metrics.spacing8)
    }

    /// The sidebar's New session control: the existing action today's toolbar "+" performs, with the
    /// app-owned ⌘N shortcut shown as a display-only hint — no new `keyboardShortcut` is attached
    /// here, because the shortcut already belongs to the app's command handling. VoiceOver hears
    /// the plain "New session" label; the hint is hidden from it.
    private var newSessionButton: some View {
        Button(action: { viewModel.didTapNewSession() }) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Image(systemName: "plus")
                    .font(.pb(.body, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                Text("New session")
                Spacer(minLength: PbRadius.Metrics.spacing4)
                Text("⌘N")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MonitorButtonStyle(.glass))
        .help("New session")
        .accessibilityLabel("New session")
    }

    private var searchField: some View {
        HStack(spacing: PbRadius.Metrics.spacing6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryText)
            TextField("Search loaded history", text: Binding(get: { viewModel.searchQuery }, set: { viewModel.didChangeSearchQuery($0) }))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, PbRadius.Metrics.spacing10)
        .padding(.vertical, PbRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
    }

    /// The backend filter as a compact control beside the search field: one dot per catalog entry
    /// besides "all" (unknown and history-only backends included), the selected name, and a
    /// chevron. The menu's choices, not-found titles, accessibility value and the degraded-catalog
    /// note are exactly today's.
    private var backendFilterMenu: some View {
        Menu {
            ForEach(viewModel.backendTabs) { tab in
                Button {
                    viewModel.didSelectBackendFilter(tab.id)
                } label: {
                    if tab.id == viewModel.selectedBackend {
                        Label(menuTitle(for: tab), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(for: tab))
                    }
                }
            }
        } label: {
            SidebarBackendFilterLabel(
                backendIDs: viewModel.backendTabs.filter { $0.id != "all" }.map(\.id),
                selectedTitle: viewModel.selectedBackend == "all" ? nil : selectedTitle
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Backend filter")
        .accessibilityValue(selectedTitle)
    }

    private var selectedTitle: String {
        viewModel.selectedBackend == "all" ? "All agents" : BackendStyle.displayName(viewModel.selectedBackend)
    }

    private func menuTitle(for tab: BackendTab) -> String {
        if tab.id == "all" { return "All agents" }
        let name = BackendStyle.displayName(tab.id)
        return tab.isNotFound ? "\(name) (not found on PATH)" : name
    }

    /// One source's history surface (SPEC §4): the blocked/partial-history diagnostics, the
    /// loading indicator, the error with its retry, and — only while more history actually exists
    /// — the manual "Load older" control. The exhausted end-of-history row is gone: history that
    /// has nothing left to show or retry renders nothing at all.
    private func historyControl(_ source: String, state: HistoryLoadingState, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            if state.catalogState.status == .blocked {
                Text(state.catalogState.reason ?? "History indexing is blocked. Resolve the reported record issue, then retry.")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.warningFG)
            } else if state.authorityIncomplete {
                Text("History is blocked by a large legacy record. Inspect a known task directly to restore access.")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
            } else if state.historyIncomplete {
                Text("Some large legacy records need direct inspection; history ordering is incomplete.")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
            }
            if state.isLoading {
                LoadingLabel("Loading \(source.lowercased())…")
            } else if let error = state.error {
                Text(error.message).font(.pb(.caption)).foregroundStyle(Color.failedRed)
                Button("Retry \(source.lowercased())", action: action)
            } else if state.authorityIncomplete || state.catalogState.status == .blocked {
                Button("Retry \(source.lowercased())", action: action)
            } else if state.bootstrapPending {
                Text("Preparing \(source.lowercased()) history…").font(.pb(.caption))
                Button("Retry \(source.lowercased())", action: action)
            } else if state.hasMore {
                Button("Load older \(source.lowercased())", action: action)
            }
        }.frame(minHeight: max(PbRadius.Metrics.sidebarHistoryMinimumHeight, minimumRowHeight), alignment: .leading)
    }

    /// Whether a source still owes the person anything: a diagnostic, a retry, a load in flight, or
    /// a further page. Settled, exhausted history renders no rows and no header at all.
    private func needsPresentation(_ state: HistoryLoadingState) -> Bool {
        state.catalogState.status == .blocked || state.authorityIncomplete || state.historyIncomplete
            || state.isLoading || state.error != nil || state.bootstrapPending || state.hasMore
    }

    private var list: some View {
        List(selection: Binding(get: { viewModel.selection }, set: { destination in
            viewModel.didSelect(destination)
        })) {
            workflowDefinitions
            if let bannerModel = viewModel.installBannerModel {
                Section {
                    InstallBanner(
                        model: bannerModel,
                        onPrimary: { viewModel.didTapInstallBannerPrimary() },
                        onSecondary: { viewModel.didTapInstallBannerSecondary() },
                        onDismiss: { viewModel.didTapInstallBannerDismiss() }
                    )
                }
            } else if let error = viewModel.listErrorMessage {
                Section {
                    Text(error).font(.pb(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
                }
            }
            if viewModel.showsLoadingSkeleton {
                Section { SkeletonRows() }
            } else {
                ForEach(displayedSections ?? viewModel.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            SidebarDisclosureRow(isVisible: !fadingRowIDs.contains(item.id), animate: !seenRowIDs.contains(item.id), minimumHeight: minimumRowHeight) {
                                itemView(item)
                            }
                                .transition(.identity)
                                .allowsHitTesting(!fadingRowIDs.contains(item.id))
                                .accessibilityHidden(fadingRowIDs.contains(item.id))
                                .onAppear { seenRowIDs.insert(item.id) }
                                .listRowInsets(EdgeInsets(
                                    top: PbRadius.Metrics.zero, leading: PbRadius.Metrics.sidebarRowInsetHorizontal,
                                    bottom: PbRadius.Metrics.zero, trailing: PbRadius.Metrics.sidebarRowInsetHorizontal
                                ))
                        }
                    } header: {
                        SidebarSectionHeading(text: section.title)
                    }
                }
                if needsPresentation(viewModel.taskHistoryState) || needsPresentation(viewModel.workflowHistoryState) {
                    Section {
                        if needsPresentation(viewModel.taskHistoryState) {
                            historyControl("Tasks", state: viewModel.taskHistoryState, action: viewModel.didTapLoadMoreTasks)
                        }
                        if needsPresentation(viewModel.workflowHistoryState) {
                            historyControl("Workflows", state: viewModel.workflowHistoryState, action: viewModel.didTapLoadMoreWorkflows)
                        }
                    } header: {
                        SidebarSectionHeading(text: "History")
                    }
                }
                if let message = viewModel.emptyStateMessage {
                    Text(message)
                        .font(.pb(.body))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear
.frame(height: PbRadius.Metrics.hairlineStroke)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: SidebarHistoryViewportKey.self,
                            value: SidebarHistoryViewport(bottom: geometry.frame(in: .global),
                                token: historyLayoutToken, revision: viewModel.historyPresentationRevision))
                    })
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarHistoryViewportKey.self,
                value: SidebarHistoryViewport(viewport: geometry.frame(in: .global)))
        })
        .onPreferenceChange(SidebarHistoryViewportKey.self) { geometry in
            viewModel.didChangeHistoryBottomVisibility(geometry.isBottomVisible, revision: geometry.revision)
        }
        .listStyle(.sidebar)
        // The first section header ("Running" whenever anything runs) otherwise sits flush against
        // the list's top edge and is clipped under the filter row.
        .padding(.top, PbRadius.Metrics.spacing8)
        // Native List otherwise keeps closed rows at its minimum height until deletion.
        .environment(\.defaultMinListRowHeight, 0)
        .animation(PbMotion.disclosure(reduceMotion: reduceMotion), value: expansionToken)
        .pbFadeIn()
        .onChange(of: viewModel.sections) { old, new in reconcileRows(from: old, to: new) }
        .onDisappear {
            disclosureTask?.cancel()
            displayedSections = nil
            fadingRowIDs = []
        }
        .onMoveCommand { direction in
            withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didPressMoveCommand(direction) }
        }
    }

    /// A content change requests a fresh layout even when the trailing frame is unchanged.
    private var historyLayoutToken: String {
        let sections = displayedSections ?? viewModel.sections
        let rowCount = sections.reduce(0) { $0 + $1.items.count }
        let lastRow = sections.last?.items.last?.id ?? ""
        let taskCursor = viewModel.taskHistoryState.nextCursor ?? ""
        let workflowCursor = viewModel.workflowHistoryState.nextCursor ?? ""
        return "\(rowCount):\(lastRow):\(taskCursor):\(workflowCursor)"
            + ":\(viewModel.taskHistoryState.isLoading):\(viewModel.workflowHistoryState.isLoading)"
    }

    @ViewBuilder
    private func itemView(_ item: SidebarItem) -> some View {
        switch item {
        case .task(let row):
            TaskRow(model: row, onToggleExpansion: row.hasChildren ? { toggleExpansion(row.id) } : nil, sidebarAppearance: SidebarRowAppearance())
                .tag(MonitorDestination.task(row.id))
        case .group(let group):
            HStack(spacing: PbRadius.Metrics.rowItemSpacing) {
                GroupRow(group: group.group, conversations: group.conversations, sidebarAppearance: SidebarRowAppearance())
                if group.conversations.count > 1 {
                    Button { toggleExpansion(group.id) } label: {
                        SidebarGroupDisclosure(isExpanded: group.isExpanded, reduceMotion: reduceMotion)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Expand or collapse \(group.name)")
                    .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
                }
            }.tag(MonitorDestination.group(group.name))
        case .workflow(let row):
            // A workflow run's duplicate alias fill: `selectedRow` where the old accent tint was,
            // still painted below the native selection NSOutlineView draws above it. The row's
            // timestamps render secondary there — tertiary misses 4.5:1 on this fill in dark.
            TaskRow(
                model: row,
                onToggleExpansion: row.hasChildren ? { toggleExpansion("workflow:\(row.id)") } : nil,
                sidebarAppearance: SidebarRowAppearance(isSelectedFill: item.isSelected(viewModel.selection))
            )
                .tag(item.destination)
                .listRowBackground(RoundedRectangle(cornerRadius: PbRadius.row)
                    .fill(item.isSelected(viewModel.selection) ? Color.selectedRow : Color.clear))
        case .workflowShortcut(let row, _):
            TaskRow(model: row, sidebarAppearance: SidebarRowAppearance(isSelectedFill: item.isSelected(viewModel.selection)))
                .tag(item.destination)
                .listRowBackground(RoundedRectangle(cornerRadius: PbRadius.row)
                    .fill(item.isSelected(viewModel.selection) ? Color.selectedRow : Color.clear))
        }
    }

    private var expansionToken: [String] {
        viewModel.sections.flatMap(\.items).compactMap { item in
            switch item {
            case .task(let row), .workflow(let row), .workflowShortcut(let row, _):
                row.hasChildren ? "\(item.id):\(row.isExpanded)" : nil
            case .group(let group):
                "\(item.id):\(group.isExpanded)"
            }
        }
    }

    private func reconcileRows(from old: [SidebarSection], to new: [SidebarSection]) {
        disclosureTask?.cancel()
        let newIDs = Set(new.flatMap(\.items).map(\.id))
        let current = displayedSections ?? old
        let removed = Set(current.flatMap(\.items).map(\.id)).subtracting(newIDs)
        seenRowIDs.formIntersection(newIDs)
        // List retains outgoing cells during its deletion animation. Keep their closed
        // presentation until that identity is explicitly reintroduced by a new snapshot.
        fadingRowIDs.formUnion(removed)
        fadingRowIDs.subtract(newIDs)
        displayedSections = SidebarSection.retainingRemovedRows(from: current, in: new)
        guard !removed.isEmpty else { return }
        // Native List removal is immediate. Keep outgoing cells while their disclosure closes,
        // then remove them; a newer snapshot cancels this pending removal.
        disclosureTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 200)) } catch { return }
            withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { displayedSections = new }
        }
    }

    private func toggleExpansion(_ id: String) {
        withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didToggleExpansion(taskID: id) }
    }

    private var workflowDefinitions: some View {
        Section(isExpanded: $workflowsExpanded.animation(PbMotion.disclosure(reduceMotion: reduceMotion))) {
                ForEach(viewModel.savedWorkflows) { workflow in
                    SidebarWorkflowDefinitionRow(title: workflow.id)
                        .font(.pb(.body, weight: .medium))
                        .frame(minHeight: minimumRowHeight)
                        .tag(MonitorDestination.workflow(workflow.id))
                        .pbFadeIn()
                }

        } header: {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Button { withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { workflowsExpanded.toggle() } } label: {
                    SidebarSectionHeading(text: "Workflows")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workflowsExpanded ? "Collapse workflows" : "Expand workflows")
                Button { viewModel.didTapNewWorkflow() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .font(.pb(.caption, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityLabel("New workflow")
                Spacer()
            }
        }
    }

    private var footer: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            Divider()
            HStack(spacing: PbRadius.Metrics.spacing6) {
                Circle()
                    .fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed)
                    .frame(width: PbRadius.Metrics.sidebarConnectionDotSize, height: PbRadius.Metrics.sidebarConnectionDotSize)
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(viewModel.listErrorMessage ?? viewModel.connectionLine)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, PbRadius.Metrics.spacing16)
            .padding(.vertical, PbRadius.Metrics.spacing12)
        }
    }
}

// MARK: - SidebarSectionHeading

/// The sidebar's own section heading (§6.1): caption-semibold `tertiaryText`, sentence case. Local
/// on purpose — the shared `SectionLabel` keeps its many later-phase consumers untouched.
private struct SidebarSectionHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(Color.tertiaryText)
    }
}

#if DEBUG
#Preview("Sidebar section heading - light") {
    SidebarSectionHeading(text: "Running").padding(PbRadius.Metrics.spacing8).preferredColorScheme(.light)
}

#Preview("Sidebar section heading - dark") {
    SidebarSectionHeading(text: "Running").padding(PbRadius.Metrics.spacing8).preferredColorScheme(.dark)
}
#endif

/// List may construct rows before they enter the viewport. Geometry, not onAppear, gates paging.
private struct SidebarHistoryViewport: Equatable, Sendable {
    var viewport: CGRect = .null
    var bottom: CGRect = .null
    var token = ""
    var revision = -1
    var isBottomVisible: Bool {
        !viewport.isNull && !bottom.isNull && viewport.height > 0
            && bottom.maxY >= viewport.minY && bottom.minY <= viewport.maxY
    }
}

private struct SidebarHistoryViewportKey: PreferenceKey {
    static let defaultValue = SidebarHistoryViewport()
    static func reduce(value: inout SidebarHistoryViewport, nextValue: () -> SidebarHistoryViewport) {
        let next = nextValue()
        if !next.viewport.isNull { value.viewport = next.viewport }
        if !next.bottom.isNull { value.bottom = next.bottom; value.token = next.token; value.revision = next.revision }
    }
}
