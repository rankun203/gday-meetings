import AppKit
import SwiftUI

/// Local capabilities share the provider form, but have no remote connection fields.
struct LocalSpeakerProviderView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var drafts: ProviderDraftCoordinator
    @ObservedObject private var health = ProviderHealthStore.shared
    @ObservedObject private var localModels = LocalModelManager.shared
    @Binding var draft: ServiceProvider
    @ViewState private var failure: String?

    private var choices: [LocalModelID] {
        draft.kind == .nemotron
            ? LocalModelID.allCases.filter { $0.rawValue.hasPrefix("nemotron") }
            : [.community1]
    }
    private var modelID: LocalModelID? { LocalModelID(rawValue: draft.model) }
    private var changed: Bool { store.settings.serviceProviders.first { $0.id == draft.id } != draft }
    private var modelHealthIdentity: [LocalModelID: LocalModelState.HealthIdentity] {
        let savedModel = store.settings.serviceProviders.first { $0.id == draft.id }
            .flatMap { LocalModelID(rawValue: $0.model) }
        return localModels.states.filter { $0.key == savedModel || $0.key == .voiceEmbedding }
            .mapValues(\.healthIdentity)
    }

    var body: some View {
        Form {
            Section {
                Label(draft.kind.title, systemImage: draft.kind.systemImage)
                    .font(.title2.weight(.semibold))
                TextField("Name", text: $draft.name)
                Toggle("Enable This Provider", isOn: $draft.isEnabled)
                Text("Audio and speaker association stay on this Mac. Model downloads connect to Hugging Face.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Capabilities") {
                ForEach(ProviderCapability.allCases.filter { draft.kind.capabilities.contains($0) }) { capability in
                    Toggle(
                        capability.title,
                        isOn: Binding(
                            get: { draft.enabledCapabilities.contains(capability) },
                            set: { enabled in
                                if enabled {
                                    draft.enabledCapabilities.insert(capability)
                                }
                                else {
                                    draft.enabledCapabilities.remove(capability)
                                }
                            }))
                }
                Text(
                    draft.kind == .nemotron
                        ? "Adds speaker labels during recording independently of live transcription."
                        : "Labels speakers in saved audio without transcribing again. Speaker Association uses compatible voice samples from the People Library."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Readiness") {
                ForEach(ProviderCapability.allCases.filter { draft.kind.capabilities.contains($0) }) { capability in
                    let result = health.validationState(providerID: draft.id, capability: capability)
                    ProviderHealthSummary(title: capability.title, health: result)
                }
            }
            Section("Model") {
                Picker("Preset", selection: $draft.model) {
                    ForEach(choices) { id in Text(LocalModelRegistry.descriptor(id).title).tag(id.rawValue) }
                }
                if let modelID {
                    let descriptor = LocalModelRegistry.descriptor(modelID)
                    if let seconds = descriptor.inputBufferSeconds {
                        Text(
                            "Requires \(seconds.formatted(.number.precision(.fractionLength(2)))) seconds of audio before processing. Speaker labels can arrive later."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let capacity = descriptor.speakerCapacity {
                        Text(
                            "Up to \(capacity) speaker channels per audio source. Additional speakers may share a label."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    LocalModelDownloadView(modelID: modelID).id(modelID)
                }
                Text("Changes apply to the next recording or labeling job.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.kind == .nemotron || draft.enabledCapabilities.contains(.speakerRecognition) {
                Section("Speaker Association Model") {
                    LocalModelDownloadView(modelID: .voiceEmbedding)
                    Text(
                        "Associates speakers with people in the People Library. Speaker labels work without this model."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if let failure {
                    AppInlineMessage(text: failure, systemImage: "exclamationmark.circle", tint: .orange)
                }
                Button("Save") { save() }.disabled(
                    !changed || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .task(id: modelHealthIdentity) {
            await store.refreshProviderHealth(providerID: draft.id)
        }
    }
    private func save() {
        guard let index = store.settings.serviceProviders.firstIndex(where: { $0.id == draft.id }) else { return }
        let previous = store.settings
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.serviceProviders[index] = draft
        if !store.saveSettings() {
            store.settings = previous
            failure = store.errorMessage ?? "Couldn’t save provider settings."
        }
        else {
            drafts.clear(draft.id)
            failure = nil
            Task { await store.refreshProviderHealth(providerID: draft.id) }
        }
    }
}

struct LocalModelDownloadView: View {
    @ObservedObject private var models = LocalModelManager.shared
    let modelID: LocalModelID
    @ViewState private var failure: String?
    @ViewState private var readiness: ProviderHealth = .checking

    var body: some View {
        let state = models.state(for: modelID)
        let descriptor = LocalModelRegistry.descriptor(modelID)
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            HStack {
                Text(state.phase == .missing ? readiness.title : state.phase.settingsTitle)
                Spacer()
                Text(
                    "Model files: \(ByteCountFormatter.string(fromByteCount: descriptor.downloadBytes, countStyle: .file))"
                )
                .foregroundStyle(.secondary)
                switch state.phase {
                case .missing:
                    if readiness.isReady {
                        Button("Remove Download", role: .destructive) {
                            Task {
                                do {
                                    try await models.remove(modelID)
                                    failure = nil
                                }
                                catch { failure = error.localizedDescription }
                            }
                        }.disabled(state.inUse > 0)
                    }
                    else if readiness != .checking {
                        Button("Download") { models.download(modelID) }.disabled(state.inUse > 0)
                    }
                case .unverified:
                    ProgressView().controlSize(.small)
                case .failed, .cancelled:
                    Button("Retry") { models.retry(modelID) }.disabled(state.inUse > 0)
                case .downloading, .verifying, .preparing:
                    Button {
                        models.cancel(modelID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless).accessibilityLabel("Cancel Download")
                    .help("Cancel Download")
                case .ready:
                    Button("Remove Download", role: .destructive) {
                        Task {
                            do {
                                try await models.remove(modelID)
                                failure = nil
                            }
                            catch { failure = error.localizedDescription }
                        }
                    }.disabled(state.inUse > 0)
                }
            }
            if state.phase == .downloading {
                if let progress = state.progress {
                    ProgressView(value: progress)
                }
                else {
                    ProgressView().controlSize(.small)
                }
                Text(
                    state.totalBytes > 0
                        ? "\(ByteCountFormatter.string(fromByteCount: state.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))"
                        : "\(ByteCountFormatter.string(fromByteCount: state.completedBytes, countStyle: .file)) downloaded"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if state.phase == .preparing || state.phase == .verifying { ProgressView().controlSize(.small) }
            if state.inUse > 0 {
                Text("In use. Stop the current work before removing this model.").font(.caption).foregroundStyle(
                    .secondary)
            }
            if state.phase == .missing, let reason = readiness.reason {
                AppInlineMessage(text: reason, systemImage: "exclamationmark.circle", tint: .orange)
            }
            if let message = failure ?? state.message {
                AppInlineMessage(text: message, systemImage: "exclamationmark.circle", tint: .orange)
            }
            HStack {
                Button("Open Model Folder") { openFolder() }
                Button("Refresh") { Task { await models.refresh() } }
            }
            DisclosureGroup("Manual Installation") {
                Text("Copy the selected revision’s files into the model folder. Place these items directly inside it:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(
                    Set(descriptor.assets.map { $0.path.components(separatedBy: "/")[0] }).sorted().joined(
                        separator: ", ")
                )
                .font(.caption.monospaced()).textSelection(.enabled)
                Text(
                    "Return here and select Refresh. The app checks every file and prepares the model automatically."
                )
                .font(.caption).foregroundStyle(.secondary)
                Link(
                    "Model Files",
                    destination: URL(
                        string: "https://huggingface.co/\(descriptor.repository)/tree/\(descriptor.revision)")!
                )
                .font(.caption)
            }
            .disclosureGroupStyle(AppDisclosureStyle())
        }
        .task {
            await models.refresh([modelID])
        }
        .task(id: state.healthIdentity) {
            let result = await models.health(for: modelID)
            guard !Task.isCancelled else { return }
            readiness = result
        }
    }
    private func openFolder() {
        Task {
            do {
                let directory = try await models.openableDirectory(for: modelID)
                NSWorkspace.shared.open(directory)
            }
            catch { failure = "Couldn’t open the model folder. \(error.localizedDescription)" }
        }
    }
}

extension LocalModelPhase {
    var settingsTitle: String {
        switch self {
        case .missing: "Download Required"
        case .unverified: "Verification Required"
        case .downloading: "Downloading…"
        case .cancelled: "Download Cancelled"
        case .failed: "Model Unavailable"
        case .verifying: "Verifying…"
        case .preparing: "Preparing…"
        case .ready: "Ready"
        }
    }
}
