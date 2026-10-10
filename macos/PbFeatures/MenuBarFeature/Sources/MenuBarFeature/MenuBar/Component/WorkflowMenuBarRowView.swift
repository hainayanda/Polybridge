import PbUI
import SwiftUI

// MARK: - WorkflowMenuBarRowView

struct WorkflowMenuBarRowView: View {
    let model: WorkflowMenuBarRow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ActivityCard {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    HStack(spacing: PbRadius.Metrics.spacing8) {
                        if model.isWorking {
                            RunningSpinner().frame(width: PbRadius.Metrics.statusIconSize, height: PbRadius.Metrics.statusIconSize)
                        } else {
                            Image(systemName: model.needsAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                                .foregroundStyle(model.needsAttention ? Color.warningFG : Color.secondaryText)
                        }
                        Text(model.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                        Spacer(minLength: PbRadius.Metrics.spacing4)
                        Text(model.statusLabel).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    Text(model.detail).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

#if DEBUG
@MainActor
private func workflowMenuBarRowPreview(needsAttention: Bool) -> some View {
    let model = needsAttention
        ? WorkflowMenuBarRow([
            "workflow_run_id": .string("preview"), "name": .string("Implement and review"),
            "status": .string("needs_attention"), "attention_reason": .string("Implementation reached its attempt limit.")
        ])
        : WorkflowMenuBarRow(["workflow_run_id": .string("preview"), "name": .string("Implement and review"), "status": .string("running")])
    return Group {
        if let model { WorkflowMenuBarRowView(model: model, onTap: {}).padding().frame(width: PbRadius.Metrics.menuBarPopoverWidth) }
    }
}

#Preview("Workflow row, attention - light") {
    workflowMenuBarRowPreview(needsAttention: true).preferredColorScheme(.light)
}

#Preview("Workflow row, attention - dark") {
    workflowMenuBarRowPreview(needsAttention: true).preferredColorScheme(.dark)
}

#Preview("Workflow row, running - light") {
    workflowMenuBarRowPreview(needsAttention: false).preferredColorScheme(.light)
}

#Preview("Workflow row, running - dark") {
    workflowMenuBarRowPreview(needsAttention: false).preferredColorScheme(.dark)
}
#endif
