import SwiftUI

/// Inline feedback keeps long explanations readable and gives state a non-color cue.
struct AppInlineMessage: View {
    let text: String
    var systemImage = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Shared readiness layout for local provider capability rows.
struct ProviderHealthSummary: View {
    let title: String
    let health: ProviderHealth

    private var statusSymbol: String {
        switch health {
        case .ready: "checkmark.circle"
        case .checking: "clock"
        case .notReady: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
            LabeledContent(title) {
                Label(health.title, systemImage: statusSymbol)
                    .foregroundStyle(.secondary)
            }
            if let reason = health.reason {
                AppInlineMessage(text: reason, systemImage: "exclamationmark.circle", tint: .orange)
            }
        }
    }
}
