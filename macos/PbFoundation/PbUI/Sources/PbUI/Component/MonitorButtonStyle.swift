import SwiftUI

// MARK: - MonitorButtonStyle

/// The design's four button kinds (SPEC §5.3), one style with a `kind`:
/// - **primary**: filled `accentFill` capsule with `onAccent` semibold text — one per screen.
/// - **tinted**: a `runningBG`-style tint with `accentLink` text ("Edit with agent").
/// - **destructive**: `dangerFG` on `dangerBG`, capsule — destructive actions are always the
///   tinted danger style, never red text on white.
/// - **glass**: the SDK's native Liquid Glass capsule for secondary chrome (toolbar groups,
///   floating controls). Opt-in: content is never glass, and `QuietButtonStyle` stays neutral.
public struct MonitorButtonStyle: ButtonStyle {
    /// The button's visual kind. `primary` is the default; `glass` is for chrome only.
    public enum Kind {
        case primary
        case tinted
        case destructive
        case glass
    }

    public var kind: Kind

    public init(_ kind: Kind = .primary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        MonitorButtonBody(configuration: configuration, kind: kind)
    }
}

private struct MonitorButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: MonitorButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    private var shape: Capsule { Capsule() }

    var body: some View {
        switch kind {
        case .glass:
            // The SDK's own glass, not a painted approximation; opt-in for chrome only.
            configuration.label
                .font(.pb(.body, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, PbRadius.Metrics.secondaryButtonHorizontalPadding)
                .frame(minHeight: PbRadius.Metrics.primaryButtonHeight)
                .glassEffect(.regular.interactive(isEnabled), in: shape)
                .contentShape(shape)
        case .primary, .tinted, .destructive:
            configuration.label
                .font(.pb(.body, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: PbRadius.Metrics.primaryButtonHeight)
                .background(shape.fill(fill))
                .brightness(configuration.isPressed ? -0.04 : 0)
                .contentShape(shape)
        }
    }

    private var horizontalPadding: CGFloat {
        kind == .primary
            ? PbRadius.Metrics.primaryButtonHorizontalPadding
            : PbRadius.Metrics.secondaryButtonHorizontalPadding
    }

    private var fill: Color {
        switch kind {
        case .primary: .accentFill
        case .tinted: .runningBG
        case .destructive: .dangerBG
        case .glass: .shadow.opacity(0)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? .onAccent : .onAccent.opacity(0.5)
        case .tinted: isEnabled ? .accentLink : .accentLink.opacity(0.5)
        case .destructive: isEnabled ? .dangerFG : .dangerFG.opacity(0.5)
        case .glass: isEnabled ? .primaryText : .secondaryText
        }
    }
}

#if DEBUG
private struct MonitorButtonsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
            HStack(spacing: PbRadius.Metrics.spacing12) {
                Button("Run") {}.buttonStyle(MonitorButtonStyle(.primary))
                Button("Edit with agent") {}.buttonStyle(MonitorButtonStyle(.tinted))
                Button("Cancel run", role: .destructive) {}.buttonStyle(MonitorButtonStyle(.destructive))
                Button("Glass") {}.buttonStyle(MonitorButtonStyle(.glass))
            }
            HStack(spacing: PbRadius.Metrics.spacing12) {
                Button("Run") {}.buttonStyle(MonitorButtonStyle(.primary)).disabled(true)
                Button("Edit with agent") {}.buttonStyle(MonitorButtonStyle(.tinted)).disabled(true)
                Button("Cancel run", role: .destructive) {}.buttonStyle(MonitorButtonStyle(.destructive)).disabled(true)
                Button("Glass") {}.buttonStyle(MonitorButtonStyle(.glass)).disabled(true)
            }
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("MonitorButton kinds - light") { MonitorButtonsPreview().preferredColorScheme(.light) }
#Preview("MonitorButton kinds - dark") { MonitorButtonsPreview().preferredColorScheme(.dark) }
#endif
