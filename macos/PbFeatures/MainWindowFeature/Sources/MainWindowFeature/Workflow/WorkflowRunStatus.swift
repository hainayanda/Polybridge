import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowDecisionFallback

/// The decision line's honest fallback: "Waiting for the first step" appears only while the run
/// is still starting/running with no reason and no worker step — never beside an attention or
/// error state, and never after a step has started. The run's own reported reason wins whenever
/// one exists. Pure and testable.
enum WorkflowDecisionFallback {
    static let waitingForFirstStep = "Waiting for the first step"

    static func text(status: String, reason: String, hasWorkerStep: Bool, recoveryQuestion: String? = nil) -> String? {
        if let recoveryQuestion,
           reason.trimmingCharacters(in: .whitespacesAndNewlines) == recoveryQuestion.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        if !reason.isEmpty { return reason }
        if hasWorkerStep { return nil }
        if ["starting", "running"].contains(status) { return waitingForFirstStep }
        return nil
    }
}

/// The existing recovery eligibility, shared by the banner and its duplicate-reason suppression.
enum WorkflowRecoveryPresentation {
    static func showsRecovery(status: String, allowsMonitorControl: Bool, isDelegation: Bool) -> Bool {
        allowsMonitorControl && (["needs_attention", "paused", "needs_input"].contains(status)
            || (isDelegation && status == "failed"))
    }

    static func showsRecovery(_ run: WorkflowRunModel) -> Bool {
        showsRecovery(status: run.status, allowsMonitorControl: run.allowsMonitorControl, isDelegation: run.isDelegation)
    }
}

// MARK: - WorkflowRunStatus

struct WorkflowRunStatus<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @State private var showsDecision = false

    var body: some View {
        if let run = viewModel.selectedRun {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
                decision(run)
                WorkflowRunDiagnostics(run: run)
                if WorkflowRecoveryPresentation.showsRecovery(run) {
                    recovery(run)
                }
                if run.raw["kind"]?.stringValue == "builder", run.status == "completed" {
                    if run.isBuilderProposal {
                        Button("Apply proposal") { viewModel.applyAgentProposal() }.buttonStyle(MonitorButtonStyle(.glass))
                    } else {
                        Button("Open generated draft") { viewModel.openWorkflowEditor(run.name) }.buttonStyle(MonitorButtonStyle(.glass))
                    }
                }
                if viewModel.canReturnToCanvas {
                    Button("Return to canvas") { viewModel.returnToCanvas() }.buttonStyle(MonitorButtonStyle(.glass))
                }
                if viewModel.selectedActivationID != nil {
                    Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(MonitorButtonStyle(.glass))
                }
            }
.padding(.horizontal, PbRadius.Metrics.spacing16)
.padding(.vertical, PbRadius.Metrics.spacing10)
        }
    }

    @ViewBuilder
    private func decision(_ run: WorkflowRunModel) -> some View {
        let last = WorkflowJSON.objects(run.raw["decisions"]).last
        let deciding = run.activations.contains { $0["role"]?.stringValue == "orchestrator" && $0["status"]?.stringValue == "running" }
        // Only proven-prestart logic decides whether the waiting line is honest: a worker step
        // that has started, an attention/error state, or a reported reason each withdraw it.
        let fallback = WorkflowDecisionFallback.text(
            status: run.status,
            reason: run.reason,
            hasWorkerStep: !WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: run.activations),
            recoveryQuestion: WorkflowRecoveryPresentation.showsRecovery(run) ? run.question : nil
        )
        let lastReason = last?["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let lineText = deciding ? "Orchestrator is choosing the next step…" : (lastReason ?? fallback)
        if deciding || lineText != nil {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            if deciding {
                RunningSpinner()
            } else if lineText != nil {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.secondaryText)
            }
            if let lineText {
                Text(lineText)
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !deciding, let reason = lastReason {
                Button("Show more") { showsDecision = true }
                    .buttonStyle(.link)
                    .fixedSize()
                    .popover(isPresented: $showsDecision) {
                        ScrollView {
                            Text(reason)
.font(.pb(.body))
.textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
.padding(PbRadius.Metrics.spacing16)
                        }.frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.activityPreviewWidth)
                    }
            }
        }
    }
        }

    /// The needs-attention recovery (SPEC §6.4): the banner carries the existing question (or
    /// the existing "Scheduling is paused." fallback) and the existing settling line — nothing
    /// invented. Every existing control stays: the compact growing multiline editor, the
    /// 0…100 extra-attempts stepper, one-more-retry, optional reviewer consent, and the
    /// Resume/Recover primary with its busy/settling/requires-answer guards. On a narrow pane
    /// the controls wrap vertically instead of hiding.
    private func recovery(_ run: WorkflowRunModel) -> some View {
        let missingAnswer = run.requiresAnswer && viewModel.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack(alignment: .top, spacing: PbRadius.Metrics.spacing10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.warningFG)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                    Text(run.question.isEmpty ? "Scheduling is paused." : run.question)
                        .font(.pb(.secondary, weight: .semibold))
.foregroundStyle(Color.warningFG)
.textSelection(.enabled)
                    if run.isSettling {
                        Text("Waiting for running branches to finish…")
                            .font(.pb(.secondary))
                            .foregroundStyle(Color.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("Additional instructions")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
            WorkflowRecoveryEditor(text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: PbRadius.Metrics.spacing8) {
                    recoveryControls(run: run, missingAnswer: missingAnswer)
                }
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                    recoveryControls(run: run, missingAnswer: missingAnswer)
                }
            }.font(.pb(.body))
        }
        .padding(PbRadius.Metrics.recoveryBannerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius).fill(Color.warningBG))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius)
            .stroke(Color.warningFG.opacity(0.3), lineWidth: PbRadius.Metrics.hairlineStroke))
    }

    @ViewBuilder
    private func recoveryControls(run: WorkflowRunModel, missingAnswer: Bool) -> some View {
        Stepper(
            "Extra attempts: \(viewModel.additionalAttempts)",
            value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
            in: 0 ... 100
        )
            .fixedSize()
        if run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false {
            Button("Continue with one more retry") { viewModel.continueWithOneMoreRetry() }
                .buttonStyle(MonitorButtonStyle(.glass))
                .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
        }
        if run.canSkipOptionalReview {
            Button("Proceed without optional reviewer") {
                viewModel.control("resume", allowOptionalReviewSkip: true)
            }
            .buttonStyle(MonitorButtonStyle(.glass))
            .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
        }
        Button(run.status == "failed" ? "Recover" : "Resume") { viewModel.control(run.status == "failed" ? "recover" : "resume") }
            .buttonStyle(MonitorButtonStyle(.primary))
            .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
    }
}

#if DEBUG
#Preview("Workflow decisions and checklist - light") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: PbRadius.Metrics.toolbarPreviewWidth).preferredColorScheme(.light)
}

#Preview("Workflow decisions and checklist - dark") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: PbRadius.Metrics.toolbarPreviewWidth).preferredColorScheme(.dark)
}

#Preview("Workflow decisions and checklist - narrow, long question") {
    WorkflowRunStatus(viewModel: WorkflowPreview.makeLongQuestionRun()).frame(width: PbRadius.Metrics.toolRowPreviewWidth)
}
#endif
