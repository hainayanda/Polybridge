//
//  ParallelVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities

// MARK: - ParallelUseCase

/// The Parallel screen's data needs over `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository` and `TakeoverService`.
@Mockable
@MainActor
protocol ParallelUseCase: Sendable {

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func busyPublisher() -> AnyPublisher<Set<String>, Never>
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>
    /// Titles load off-main, separately from the listing itself (F4-11/MS-LIST-5, the same gap
    /// Codex review caught on `SidebarVM` in Phase 4b) — a column must refresh when one arrives even
    /// though the listing itself did not change.
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    /// The fresh listing entry for a member (F4-40: "using the fresh listing entry") — never a
    /// cached copy retained by this screen.
    func task(_ id: String) -> TaskInfo?
    func title(_ taskID: String) -> String

    /// Decision 6: one lease per member, acquired while its column is on screen.
    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>
    func prompt(for taskID: String) -> String?
    /// Whether the member's event log could actually be read the last time it was tailed (Monitor
    /// piece 12, Design point 4) — mirrors `TaskDetailUseCase.eventsAvailability(for:)`/
    /// `eventsAvailabilityPublisher(for:)`, backed by the same `EventStreamRepository`, so a column
    /// can tell "nothing has happened yet" apart from "there is no log to read at all" and show a
    /// skeleton only for the former.
    func eventsAvailability(for taskID: String) -> EventAvailability
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never>

    func runningInSubtrees(of ids: [String]) -> [String]
    func cancelAll(_ ids: [String]) async
    /// The durable outcome line a column shows — TaskDetail's own refusal channel.
    func setOutcome(_ id: String, _ text: String?)

    /// Dispatches into `TakeoverService` synchronously; the VM routes to the task screen immediately
    /// after calling this. Take over always opens Terminal.app.
    func beginTakeover(taskID: String)
}

/// Optional readiness seam keeps existing previews and isolated use cases independent of storage.
@MainActor
protocol ParallelActivityReadiness {
    func activityReadyPublisher() -> AnyPublisher<Bool, Never>
}

// MARK: - ParallelRouting

/// Navigation the Parallel screen performs: routing to a member's own task screen, either from
/// "Open task" or right after an embedded takeover.
@Mockable
@MainActor
protocol ParallelRouting: Sendable {
    func selectTask(_ taskID: String)
}

// MARK: - ParallelVM

/// View model for the Parallel screen: one column per group member, ported from the old
/// `ParallelView.swift`/`ParallelColumn` with no behaviour change. The column's outcome line is always
/// secondary-coloured; only TaskDetail's header turns red for "Refused".
///
/// Monitor piece 13: a column is one agent CONVERSATION (a resume chain, `MonitorCore.Conversation`),
/// not one task — a resumed member inherits its parent's `group`, so before this every resume turn
/// was its own `TaskNode` group member and so its own column (an orchestrator resuming 2 agents ×
/// 8 rounds showed as 16 columns). Membership/order come from `Lineage.sections(_:).parallel.first`'s
/// `conversations` (built once per `tasksPublisher` emission). Detailed activity leases are held
/// for every member of resident conversations; off-screen conversations retain lightweight headers.
/// Source updates freshen metadata from `useCase.task(_:)` (F4-40). Immutable resident inputs build
/// independently off-main, while complete rendering equality guards main-actor publication.
@Observable
@MainActor
final class ParallelVM: ParallelViewModel {
    
    // MARK: - ParallelViewModel Properties
    
    let groupName: String
    private(set) var headerSubtitle = ""
    private(set) var showPrompt = false
    private(set) var canCancelAll = false
    private(set) var isEmpty = false
    private(set) var columns: [ParallelColumnModel] = []
    private(set) var footerText = ParallelVM.fallbackFooter
    
    // MARK: - Private Properties
    
    static let fallbackFooter = "Enforcement differs between these agents; see each task's details."
    
    @ObservationIgnored private let useCase: any ParallelUseCase
    @ObservationIgnored private let routing: any ParallelRouting
    @ObservationIgnored private let buildColumns: ParallelColumnsBuild
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var itemCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var availabilityCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var leaseGenerations: [String: UUID] = [:]
    @ObservationIgnored private var ownerByMember: [String: String] = [:]
    @ObservationIgnored private var conversationByID: [String: Conversation] = [:]
    @ObservationIgnored private var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var itemsByTask: [String: [TimelineItem]] = [:]
    @ObservationIgnored private var availabilityByTask: [String: EventAvailability] = [:]
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored private var latestBusy: Set<String> = []
    @ObservationIgnored private var latestOutcomes: [String: String] = [:]
    /// Every task id belonging to any of this group's conversations (Monitor piece 13) — the lease
    /// diff set and cancel-all's target list. A superset of the old top-level-only `memberIDs`,
    /// since it now also names each conversation's earlier, already-terminal turns.
    @ObservationIgnored private var memberIDs: [String] = []
    /// This group's conversations as of the last `tasksPublisher` emission — membership and order
    /// only. `recompute()` always re-reads each member's own `useCase.task(_:)` before building a
    /// column (F4-40), never a `TaskInfo` cached here.
    @ObservationIgnored private var conversations: [Conversation] = []
    @ObservationIgnored private var workflowTaskIDs: [String]?
    @ObservationIgnored private var workflowFocusedTaskIDs: Set<String>?
    @ObservationIgnored private var workflowTitles: [String: String] = [:]
    @ObservationIgnored private var initialMembershipResolved = false
    @ObservationIgnored private var activityReady = false
    @ObservationIgnored private var arrivalTracker = PanelArrivalTracker()
    @ObservationIgnored private var viewportOffset: CGFloat = 0
    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored private var residentIDs: Set<String> = []
    @ObservationIgnored private var uiStates: [String: ParallelColumnUIState] = [:]
    @ObservationIgnored private var descriptors: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored private var presentations: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored private var completedInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var desiredInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pendingInputs: [String: ParallelColumnInput]?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var scheduledStart: UInt64?
    @ObservationIgnored private var latencyStart: UInt64?
    var isPresentationSettled: Bool { worker == nil && pendingInputs == nil }
    var leasedMemberCount: Int { leases.count }
    var residentColumnCount: Int { residentIDs.count }
    var retainedColumnStateCount: Int { uiStates.count }
    @ObservationIgnored private var orderedConversations: [Conversation] = []
    @ObservationIgnored private var arrivals: Set<String> = []
    @ObservationIgnored private(set) var presentationWriteCount = 0
    @ObservationIgnored private(set) var builtColumnCount = 0
    @ObservationIgnored private(set) var sourceUpdateCount = 0

    func columnState(for id: String) -> ParallelColumnUIState {
        if let state = uiStates[id] { return state }
        let state = ParallelColumnUIState()
        if conversationByID[id] != nil { uiStates[id] = state }
        return state
    }

    func updateViewport(offset: CGFloat, width: CGFloat) {
        guard viewportOffset != offset || viewportWidth != width else { return }
        let start = MonitorMetrics.begin()
        defer { MonitorMetrics.end(start, stage: .parallelViewport, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        viewportOffset = offset
        viewportWidth = width
        guard didSubscribe else { return }
        let stride = ParallelLayout.columnWidth(memberCount: orderedConversations.count, availableWidth: width)
            + ParallelLayout.dividerWidth
        let interval = ParallelResidency.indices(count: orderedConversations.count, offset: offset, width: width, stride: stride)
        let next = Set(interval.map { orderedConversations[$0].id })
        guard next != residentIDs else { return }
        let inputs = updateResidency()
        publishColumns()
        schedule(inputs)
    }
    
    // MARK: - Init
    
    init(groupName: String, useCase: any ParallelUseCase, routing: any ParallelRouting,
         buildColumns: @escaping ParallelColumnsBuild = ParallelPresentationBuilder.buildColumns) {
        self.groupName = groupName
        self.useCase = useCase
        self.routing = routing
        self.buildColumns = buildColumns
    }
    
    // MARK: - ParallelViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }

    /// Workflow membership comes from persisted dispatch associations, never group names. The
    /// existing Parallel feed, actions and per-member leases remain the activity implementation.
    func setWorkflowTaskIDs(_ ids: [String], focusedTaskIDs: Set<String>? = nil, titles: [String: String] = [:]) {
        workflowTaskIDs = ids
        workflowFocusedTaskIDs = focusedTaskIDs
        workflowTitles = titles
        if didSubscribe { recomputeMembersAndLeases() }
    }
    
    /// Idempotent teardown releases leases and subscriptions; reopening starts fresh.
    func didDisappear() {
        epoch &+= 1
        revision &+= 1
        worker?.cancel()
        pendingInputs = nil
        desiredInputs.removeAll()
        completedInputs.removeAll()
        presentations.removeAll()
        descriptors.removeAll()
        residentIDs.removeAll()
        uiStates.removeAll()
        orderedConversations.removeAll()
        viewportWidth = 0
        columns.removeAll()
        cancellables.removeAll()
        itemCancellables.removeAll()
        availabilityCancellables.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        leaseGenerations.removeAll()
        ownerByMember.removeAll()
        conversationByID.removeAll()
        itemsByTask.removeAll()
        availabilityByTask.removeAll()
        memberIDs.removeAll()
        didSubscribe = false
        activityReady = false
        initialMembershipResolved = false
        arrivalTracker = PanelArrivalTracker()
    }
    
    func didTapViewPrompt() {
        let start = MonitorMetrics.begin()
        showPrompt.toggle()
        for id in descriptors.keys { descriptors[id]?.showPrompt = showPrompt }
        var inputs = desiredInputs
        for id in inputs.keys { inputs[id]?.base.showPrompt = showPrompt }
        publishColumns()
        schedule(inputs)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
    }
    
    func didTapCancelAll() {
        guard canCancelAll else { return }
        publishDialog("Cancel every running task in this group?") {
            AlertAction(title: "Cancel all", role: .destructive) { [weak self] in
                guard let self else { return }
                // Membership is read at confirm time, not when the dialog opened: the dialog promises
                // the whole group, and a member that joined meanwhile (a new root, or a resume, which
                // `runningInSubtrees` never reaches via `spawned_by`) is part of it (PR #1 review).
                let ids = useCase.runningInSubtrees(of: memberIDs)
                Task { [useCase] in await useCase.cancelAll(ids) }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        let subscriptionEpoch = epoch
        if let readiness = useCase as? any ParallelActivityReadiness {
            readiness.activityReadyPublisher()
.receive(on: DispatchQueue.main)
.sink { [weak self] ready in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                activityReady = ready
                recompute()
            }
.store(in: &cancellables)
        } else { activityReady = true }
        
        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                sourceUpdateCount += 1
                guard !initialMembershipResolved || latestTasks != tasks else { return }
                initialMembershipResolved = true
                latestTasks = tasks
                recomputeMembersAndLeases()
            }
            .store(in: &cancellables)
        
        useCase.snapshotsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestSnapshots = snapshots
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.busyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestBusy = busy
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.outcomesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestOutcomes = outcomes
                recompute()
            }
            .store(in: &cancellables)
        
        // Titles load independently of the listing (Codex review finding): a column must refresh
        // when it changes on its own, not only when an unrelated publisher happens to fire afterward.
        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                recompute()
            }
            .store(in: &cancellables)
    }
    
    /// Resolves complete group membership for headers and actions. Geometry subsequently selects
    /// which conversations own detailed activity leases.
    private func recomputeMembersAndLeases() {
        let preparation = MonitorMetrics.begin()
        let group = Lineage.sections(latestTasks).parallel.first { $0.name == groupName }
        let groupConversations: [Conversation]
        if let workflowTaskIDs {
            let byID = Dictionary(uniqueKeysWithValues: latestTasks.map { ($0.taskID, $0) })
            let associated = workflowTaskIDs.compactMap { byID[$0] }
            groupConversations = WorkflowOrchestratorConversation.conversations(associated).filter { conversation in
                workflowFocusedTaskIDs.map { focus in conversation.members.contains { focus.contains($0.taskID) } } ?? true
            }
        } else {
            groupConversations = WorkflowOrchestratorConversation.conversations(group?.conversations.flatMap(\.members) ?? [])
        }
        let newIDs = groupConversations.flatMap { $0.members.map(\.taskID) }
        memberIDs = newIDs
        let migration = ParallelStateMigration.mapping(previous: conversations, current: groupConversations, retained: Set(uiStates.keys))
        uiStates = migration.compactMapValues { uiStates[$0] }
        conversations = groupConversations

        let cancellable = group?.anyRunning == true
        if canCancelAll != cancellable { canCancelAll = cancellable }
        let empty = groupConversations.isEmpty
        if isEmpty != empty { isEmpty = empty }

        // Freedom/repo diversity is read from each conversation's FIRST member (its starting
        // configuration) — one entry per agent, not one per turn.
        let firstMembers = groupConversations.map(\.first)
        let freedoms = Set(firstMembers.compactMap(\.freedom).map { AccessLabel.text(freedom: $0) }).sorted().joined(separator: ", ")
        let repos = Set(firstMembers.map { Format.repoName($0.repoPath) }).sorted().joined(separator: ", ")
        let count = groupConversations.count
        let subtitle = "\(count) agent\(count == 1 ? "" : "s") · \(freedoms) · \(repos)"
        + (group?.startedAt.map { " · started \(Format.time($0))" } ?? "")
        if headerSubtitle != subtitle { headerSubtitle = subtitle }

        MonitorMetrics.end(preparation, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count)
        recompute()
    }
    
    /// Items and availability change independently, so each keeps its own subscription.
    private func acquireLease(_ taskID: String) {
        guard leases[taskID] == nil else { return }
        let generation = UUID()
        leaseGenerations[taskID] = generation
        leases[taskID] = useCase.acquireEventLease(taskID)
        itemsByTask[taskID] = useCase.items(for: taskID)
        availabilityByTask[taskID] = useCase.eventsAvailability(for: taskID)
        itemCancellables[taskID] = useCase.itemsPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                guard leaseGenerations[taskID] == generation, itemsByTask[taskID] != items else { return }
                itemsByTask[taskID] = items
                refreshActivity(memberID: taskID)
            }
        availabilityCancellables[taskID] = useCase.eventsAvailabilityPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                guard leaseGenerations[taskID] == generation, availabilityByTask[taskID] != availability else { return }
                availabilityByTask[taskID] = availability
                refreshActivity(memberID: taskID)
            }
    }

    private func releaseLease(_ taskID: String) {
        leases[taskID]?.release()
        leases[taskID] = nil
        leaseGenerations[taskID] = nil
        itemCancellables[taskID]?.cancel()
        itemCancellables[taskID] = nil
        availabilityCancellables[taskID]?.cancel()
        availabilityCancellables[taskID] = nil
        itemsByTask[taskID] = nil
        availabilityByTask[taskID] = nil
    }
    
    /// Source changes freshen metadata for every conversation (F4-40), then capture value inputs
    /// for resident columns. Activity and viewport hot paths reuse this ownership/order skeleton.
    private func recompute() {
        let preparationStart = MonitorMetrics.begin()
        defer { MonitorMetrics.end(preparationStart, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        let freshened = conversations.map { conversation in
            Conversation(members: conversation.members.map { useCase.task($0.taskID) ?? $0 })
        }
        orderedConversations = Lineage.parallelColumnOrder(freshened)
        conversationByID = Dictionary(uniqueKeysWithValues: orderedConversations.map { ($0.id, $0) })
        ownerByMember = [:]
        for conversation in orderedConversations {
            for member in conversation.members { ownerByMember[member.taskID] = conversation.id }
        }
        let known = Set(latestTasks.map(\.taskID))
        let resolved = workflowTaskIDs?.allSatisfy { known.contains($0) } ?? true
        arrivals = arrivalTracker.update(orderedConversations.map { (id: $0.id, startedAt: $0.first.startedAt) },
                                         authoritative: activityReady && initialMembershipResolved && resolved)
        descriptors = Dictionary(uniqueKeysWithValues: orderedConversations.map { ($0.id, basePresentation($0, includePrompt: false)) })
        let inputs = updateResidency()
        publishColumns()
        let footerTasks = orderedConversations.map { latestSnapshots[$0.current.taskID] ?? $0.current }
        let footer = EnforcementText.common(footerTasks) ?? Self.fallbackFooter
        if footerText != footer { footerText = footer }
        schedule(inputs)
    }

    private func updateResidency() -> [String: ParallelColumnInput] {
        let stride = ParallelLayout.columnWidth(memberCount: orderedConversations.count, availableWidth: viewportWidth)
            + ParallelLayout.dividerWidth
        let interval = ParallelResidency.indices(count: orderedConversations.count, offset: viewportOffset,
                                                 width: viewportWidth, stride: stride)
        residentIDs = Set(interval.map { orderedConversations[$0].id })
        let leaseStart = MonitorMetrics.begin()
        let needed = Set(orderedConversations.filter { residentIDs.contains($0.id) }.flatMap { $0.members.map(\.taskID) })
        for id in Set(leases.keys).subtracting(needed) { releaseLease(id) }
        for id in needed.subtracting(Set(leases.keys)) { acquireLease(id) }
        MonitorMetrics.end(leaseStart, stage: .parallelLeases, residentColumns: residentIDs.count, leasedMembers: leases.count)
        for id in Set(presentations.keys).subtracting(residentIDs) {
            presentations[id] = nil
            completedInputs[id] = nil
        }
        var inputs: [String: ParallelColumnInput] = [:]
        for conversation in orderedConversations where residentIDs.contains(conversation.id) {
            inputs[conversation.id] = captureInput(conversation)
        }
        return inputs
    }

    private func refreshActivity(memberID: String) {
        guard let id = ownerByMember[memberID], residentIDs.contains(id), let conversation = conversationByID[id] else { return }
        let start = MonitorMetrics.begin()
        var inputs = desiredInputs
        inputs[id] = captureInput(conversation)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
        schedule(inputs)
    }

    private func captureInput(_ conversation: Conversation) -> ParallelColumnInput {
        let members = conversation.members.map { member in
            let snapshot = WorkflowNodePresentation.merged(latestSnapshots[member.taskID], with: member)
            return ParallelMemberInput(task: snapshot, items: itemsByTask[member.taskID] ?? [],
                prompt: snapshot.raw["display_prompt"]?.stringValue ?? useCase.prompt(for: member.taskID),
                availability: availabilityByTask[member.taskID] ?? .loading)
        }
        return ParallelColumnInput(base: basePresentation(conversation), members: members,
            events: useCase.events(for: conversation.current.taskID), snapshot: latestSnapshots[conversation.current.taskID])
    }

    private func basePresentation(_ conversation: Conversation, includePrompt: Bool = true) -> ParallelColumnPresentation {
        let current = WorkflowNodePresentation.merged(latestSnapshots[conversation.current.taskID], with: conversation.current)
        let currentID = current.taskID
        let resident = includePrompt && residentIDs.contains(conversation.id)
        let promptTask = WorkflowNodePresentation.isWorker(current) ? current :
            WorkflowNodePresentation.merged(latestSnapshots[conversation.first.taskID], with: conversation.first)
        let prompt = resident ? (promptTask.raw["display_prompt"]?.stringValue ?? useCase.prompt(for: promptTask.taskID)) : nil
        let summary = includePrompt ? latestSnapshots[currentID]?.summary : nil
        return ParallelColumnPresentation(id: conversation.id, task: current,
            title: workflowTitles[currentID] ?? useCase.title(conversation.first.taskID),
            subtitle: ParallelColumnModel.subtitle(repoPath: current.repoPath, backend: current.backend, turns: conversation.members.count),
            isBusy: latestBusy.contains(currentID), outcomeMessage: latestOutcomes[currentID], showPrompt: showPrompt,
            prompt: prompt, summary: summary, start: conversation.first.startedAt,
            memberTaskIDs: Set(conversation.members.map(\.taskID)))
    }

    private func publishColumns() {
        let start = MonitorMetrics.begin()
        let oldWrites = presentationWriteCount
        defer {
            MonitorMetrics.end(start, stage: .parallelApply, renderingWrites: presentationWriteCount - oldWrites,
                               residentColumns: residentIDs.count, leasedMembers: leases.count)
        }
        let next = orderedConversations.map { conversation in
            let presentation = presentations[conversation.id] ?? descriptors[conversation.id] ?? basePresentation(conversation, includePrompt: false)
            var column = ParallelColumnModel(id: presentation.id, task: presentation.task, title: presentation.title,
                subtitle: presentation.subtitle, isBusy: presentation.isBusy, outcomeMessage: presentation.outcomeMessage,
                showPrompt: presentation.showPrompt, prompt: presentation.prompt, rows: presentation.rows,
                activityRows: presentation.activityRows, liveStep: presentation.liveStep,
                pendingMessages: presentation.pendingMessages, isLoading: presentation.isLoading, summary: presentation.summary,
                onTapTakeover: { [weak self] in self?.didTapTakeover(taskID: presentation.task.taskID) },
                onTapOpenTask: { [weak self] in self?.routing.selectTask(presentation.task.taskID) }, start: presentation.start)
            column.animatesArrival = arrivals.contains(column.id)
            column.onDidPresent = { [weak self] in self?.arrivalTracker.didPresent(conversation.id) }
            column.memberTaskIDs = presentation.memberTaskIDs
            column.isResident = residentIDs.contains(column.id)
            return column
        }
        guard columns.map(\.renderValue) != next.map(\.renderValue) else { return }
        columns = next
        presentationWriteCount += 1
    }

    private func schedule(_ inputs: [String: ParallelColumnInput]) {
        guard desiredInputs != inputs else { return }
        desiredInputs = inputs
        revision &+= 1
        pendingInputs = inputs
        scheduledStart = MonitorMetrics.begin()
        latencyStart = scheduledStart
        worker?.cancel()
        if worker == nil { startPending() }
    }

    private nonisolated static func isBackgroundThread() -> Bool { !Thread.isMainThread }

    private func startPending() {
        guard didSubscribe, let inputs = pendingInputs else { return }
        pendingInputs = nil
        let buildRevision = revision
        let buildEpoch = epoch
        let queueStart = scheduledStart
        let updateStart = latencyStart
        let dirty = inputs.filter { completedInputs[$0.key] != $0.value }
        let build = buildColumns
        let detached = Task.detached(priority: .utility) { () -> [String: ParallelColumnPresentation]? in
            MonitorMetrics.end(queueStart, stage: .parallelScheduling, backgroundThread: Self.isBackgroundThread())
            return await build(dirty)
        }
        worker = Task { [weak self] in
            let result = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            guard let self else { return }
            if didSubscribe, epoch == buildEpoch, revision == buildRevision, let result {
                builtColumnCount += result.count
                for (id, presentation) in result where residentIDs.contains(id) && desiredInputs[id] == inputs[id] {
                    presentations[id] = presentation
                    completedInputs[id] = inputs[id]
                }
                publishColumns()
                MonitorMetrics.end(updateStart, stage: .parallelUpdateLatency)
            }
            worker = nil
            startPending()
        }
    }

    private func didTapTakeover(taskID: String) {
        guard WorkflowNodePresentation.allowsTerminal(latestSnapshots[taskID] ?? useCase.task(taskID)) else { return }
        guard let task = useCase.task(taskID) else { return }
        let isRunning = task.status.isRunning
        let title = isRunning ? "Take over this task?" : "Continue this session in a terminal?"
        let buttonTitle = isRunning ? "Stop it and take over" : "Continue in terminal"
        let message = "The headless run is stopped first if it is still going, then the same conversation opens in Terminal.app. It runs "
        + "under your own default permissions, not \(task.freedom ?? "this task's freedom")."
        publishDialog(title, description: message) {
            AlertAction(title: buttonTitle) { [weak self] in
                guard let self else { return }
                guard !refuseIfConversationMovedOn(from: taskID) else { return }
                // Dispatches synchronously into a service-owned task, then routes immediately —
                // decision 5's call path, kept exact (`ParallelView.swift:~123-127`).
                useCase.beginTakeover(taskID: taskID)
                routing.selectTask(taskID)
            }
        }
    }

    /// Refuse takeover when a conversation gained a newer member while its dialog was open.
    private func refuseIfConversationMovedOn(from dialogTaskID: String) -> Bool {
        let conversation = conversations.first { $0.members.contains { $0.taskID == dialogTaskID } }
        let currentID = conversation?.current.taskID
        guard currentID != dialogTaskID else { return false }
        useCase.setOutcome(currentID ?? dialogTaskID, "The conversation moved on — review and try again.")
        return true
    }
}
