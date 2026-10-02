import SwiftUI

struct ProviderReadinessRow: View {
    @ObservedObject private var health = ProviderHealthStore.shared
    let provider: ServiceProvider
    let selectProvider: () -> Void
    @ViewState private var showsIssues = false

    private var issues: [String] {
        provider.enabledCapabilities.compactMap { capability in
            health.state(providerID: provider.id, capability: capability).reason
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    provider.name,
                    systemImage: provider.kind.isLocal
                        ? "desktopcomputer" : provider.kind == .gdayWebsite ? "globe" : "server.rack"
                )
                .fixedSize(horizontal: false, vertical: true)
                if !provider.isEnabled || provider.name != provider.kind.title {
                    Text(provider.isEnabled ? provider.kind.title : "Disabled")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !issues.isEmpty {
                Button {
                    selectProvider()
                    showsIssues = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.yellow)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show provider readiness for \(provider.name)")
                .accessibilityLabel("Provider readiness for \(provider.name)")
                .popover(isPresented: $showsIssues) {
                    ProviderReadinessDetails(issues: issues) {
                        selectProvider()
                        showsIssues = false
                    }
                }
            }
            else {
                Color.clear.frame(width: 28, height: 28).accessibilityHidden(true)
            }
        }
    }
}

struct ProviderReadinessDetails: View {
    let issues: [String]
    let showModels: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider Readiness").font(.headline)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, message in
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Provider Settings", action: showModels)
        }
        .padding(16).frame(width: 320, alignment: .leading)
    }
}
