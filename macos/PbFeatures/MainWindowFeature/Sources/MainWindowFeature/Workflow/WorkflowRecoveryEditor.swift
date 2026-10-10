import PbUI
import SwiftUI

// MARK: - WorkflowRecoveryEditor

/// Keeps the existing native multiline editor and scrolling, growing from the compact minimum
/// to the existing maximum as the actual wrapped instructions grow.
struct WorkflowRecoveryEditor: View {
    @Binding var text: String
    @State private var measuredHeight = PbRadius.Metrics.recoveryEditorMinimumHeight

    var body: some View {
        TextEditor(text: $text)
            .font(.pb(.body))
            .frame(height: min(PbRadius.Metrics.recoveryEditorMaximumHeight,
                               max(PbRadius.Metrics.recoveryEditorMinimumHeight, measuredHeight)))
            .background(alignment: .topLeading) {
                Text(text + "\n")
                    .font(.pb(.body))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PbRadius.Metrics.spacing5)
                    .padding(.vertical, PbRadius.Metrics.spacing8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height.isFinite, height != measuredHeight { measuredHeight = height }
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
            .accessibilityLabel("Additional instructions")
    }
}

#if DEBUG
#Preview("Recovery instructions - light") {
    WorkflowRecoveryEditor(text: .constant("")).frame(width: PbRadius.Metrics.formPreviewWidth).preferredColorScheme(.light)
}

#Preview("Recovery instructions - dark, wrapped") {
    WorkflowRecoveryEditor(text: .constant("Please retry after inspecting the error.\nKeep the existing changes.\nReport the remaining issue."))
        .frame(width: PbRadius.Metrics.formPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
