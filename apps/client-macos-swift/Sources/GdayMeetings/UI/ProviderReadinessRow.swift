import SwiftUI

/// Readiness is independent of the selected sidebar row and never starts a download.
enum ProviderModelReadiness {
    static func issues(
        provider: ServiceProvider, liveRecognitionEnabled: Bool, states: [LocalModelID: LocalModelState]
    ) -> [String] {
        guard provider.isEnabled, provider.kind.isLocal else { return [] }
        var models: [LocalModelID] = []
        var messages: [String] = []
        if provider.kind == .nemotron, provider.enabledCapabilities.contains(.liveDiarization) {
            if let model = LocalModelID(rawValue: provider.model), model.nemotronPreset != nil {
                models.append(model)
            }
            else {
                messages.append("The selected live diarization preset is unavailable. Choose a supported preset.")
            }
            if liveRecognitionEnabled { models.append(.voiceEmbedding) }
        }
        if provider.kind == .community1 {
            if provider.enabledCapabilities.contains(.diarization) {
                if provider.model == LocalModelID.community1.rawValue {
                    models.append(.community1)
                }
                else {
                    messages.append("The selected diarization model is unavailable. Choose Community-1.")
                }
            }
            if provider.enabledCapabilities.contains(.speakerRecognition) { models.append(.voiceEmbedding) }
        }
        for model in models {
            let state = states[model] ?? LocalModelState()
            guard state.phase != .ready else { continue }
            let title = model == .voiceEmbedding ? "Voice Matching Model" : LocalModelRegistry.descriptor(model).title
            messages.append("\(title): \(state.phase.settingsTitle)")
            if let message = state.message, !message.isEmpty { messages.append(message) }
        }
        return messages
    }
}

struct ProviderReadinessRow: View {
    @ObservedObject private var models = LocalModelManager.shared
    let provider: ServiceProvider
    let liveRecognitionEnabled: Bool
    let selectProvider: () -> Void
    @ViewState private var showsIssues = false

    private var issues: [String] {
        ProviderModelReadiness.issues(
            provider: provider, liveRecognitionEnabled: liveRecognitionEnabled, states: models.states)
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
                .help("Show model readiness for \(provider.name)")
                .accessibilityLabel("Model readiness for \(provider.name)")
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
            Text("Model Readiness").font(.headline)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, message in
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            Button("Show Model Controls", action: showModels)
        }
        .padding(16).frame(width: 320, alignment: .leading)
    }
}
