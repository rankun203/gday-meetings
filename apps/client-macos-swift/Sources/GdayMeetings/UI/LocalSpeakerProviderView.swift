import AppKit
import SwiftUI

/// Local capabilities share the provider form, but have no remote connection fields.
struct LocalSpeakerProviderView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var health = ProviderHealthStore.shared
    @ObservedObject private var localModels = LocalModelManager.shared
    @ViewState private var draft: ServiceProvider
    @ViewState private var failure: String?

    init(provider: ServiceProvider) { _draft = ViewState(initialValue: provider) }

    private var choices: [LocalModelID] {
        draft.kind == .nemotron
            ? LocalModelID.allCases.filter { $0.rawValue.hasPrefix("nemotron") }
            : [.community1]
    }
    private var modelID: LocalModelID? { LocalModelID(rawValue: draft.model) }
    private var changed: Bool { store.settings.serviceProviders.first { $0.id == draft.id } != draft }

    var body: some View {
        Form {
            Section {
                Label(draft.kind.title, systemImage: "waveform.badge.person.crop")
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
                    let result = health.state(providerID: draft.id, capability: capability)
                    LabeledContent(capability.title, value: result.title)
                    if let reason = result.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
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
                if let failure { Text(failure).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("Save") { save() }.disabled(
                    !changed || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { await store.refreshProviderHealth(providerID: draft.id) }
        .onReceive(localModels.$states) { _ in
            Task { await store.refreshProviderHealth(providerID: draft.id) }
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
        VStack(alignment: .leading, spacing: 8) {
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
                        Button("Verify…") { models.verify(modelID) }.disabled(state.inUse > 0)
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
                    Button("Verify…") { models.verify(modelID) }.disabled(state.inUse > 0)
                case .failed, .cancelled:
                    Button("Retry") { models.retry(modelID) }.disabled(state.inUse > 0)
                case .downloading, .verifying, .preparing:
                    Button {
                        models.cancel(modelID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Cancel Download")
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
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let message = failure ?? state.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                    "Return here and select Refresh, then Verify. Verification checks every file before preparing the model."
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
        .task { readiness = await models.health(for: modelID) }
        .onReceive(models.$states) { _ in Task { readiness = await models.health(for: modelID) } }
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
