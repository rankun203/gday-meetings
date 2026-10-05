import AppKit
import SwiftUI

struct LocalSearchProviderView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var drafts: ProviderDraftCoordinator
    @ObservedObject private var health = ProviderHealthStore.shared
    @ObservedObject var controller: VoiceSearchController
    @Binding var draft: ServiceProvider
    @ViewState private var failure: String?

    private var changed: Bool { store.settings.serviceProviders.first { $0.id == draft.id } != draft }
    private var readiness: ProviderHealth { health.state(providerID: draft.id, capability: .search) }

    var body: some View {
        Form {
            Section {
                Label(draft.kind.title, systemImage: draft.kind.systemImage).font(.title2.weight(.semibold))
                TextField("Name", text: $draft.name)
                Toggle("Enable This Provider", isOn: $draft.isEnabled)
                Text(
                    "Searches descriptions of voices in recorded audio on this Mac. CLSP is experimental; results may miss relevant clips."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Configuration") {
                pathRow("Worker Executable", keyPath: \.executableURL, directory: false)
                pathRow("Model Folder", keyPath: \.modelCacheURL, directory: true)
                LabeledContent("Model", value: LocalSearchConfiguration.modelID)
                Text(
                    "Install the local Python worker and prepare its pinned model before choosing these paths. Saving settings does not download a model or index recordings."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Readiness") {
                ProviderHealthSummary(title: "Voice Search", health: readiness)
                Text(
                    "Readiness checks the executable and prepared-model metadata. It does not start the worker or measure search quality."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { Task { await store.refreshProviderHealth(providerID: draft.id) } }
                    .disabled(changed)
            }
            Section("Voice Index") {
                Text(
                    "Build the index to make saved recordings searchable by voice description. This processes audio locally and can take time. Text search remains available."
                )
                .font(.callout)
                if let progress = controller.progress {
                    ProgressView(value: Double(progress.completedClips), total: Double(max(1, progress.totalClips)))
                    Text(
                        "\(progress.completedClips.formatted()) of \(progress.totalClips.formatted()) clips in the current track"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let status = controller.statusMessage { Text(status).font(.callout) }
                if let error = controller.error {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.circle", tint: .orange)
                }
                HStack {
                    Button("Build Voice Index") {
                        if let configuration = draft.localSearch {
                            controller.buildLibrary(
                                configuration: configuration, libraryIndex: store.libraryIndex,
                                excludingTagIDs: Set(store.tags.filter(\.isExcluded).map(\.id)),
                                excludingMeetingIDs: Set([store.recordingID].compactMap { $0 }))
                        }
                    }
                    .disabled(
                        changed || !readiness.isReady || controller.isBuilding || !store.libraryWritable
                            || store.recordingID != nil
                            || store.isFinalizingRecording)
                    if controller.isBuilding { Button("Stop", role: .cancel) { controller.cancel() } }
                }
                Button("Rebuild from Saved Embeddings") { controller.rebuildSavedEmbeddings() }
                    .disabled(!store.libraryWritable || controller.isBuilding)
                Text(
                    "Rebuilding restores the local index from saved embeddings without loading the model or processing audio again."
                )
                .font(.caption).foregroundStyle(.secondary)
                if changed {
                    Text("Save your changes before building the index.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if let failure { AppInlineMessage(text: failure, systemImage: "exclamationmark.circle", tint: .orange) }
                HStack {
                    Button("Save", action: save)
                        .disabled(!changed || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(
                        store.settings.searchProviderID == draft.id
                            ? "Selected for Voice Search" : "Use for Voice Search"
                    ) {
                        let previous = store.settings
                        store.settings.selectProvider(draft.id, for: .search)
                        if !store.saveSettings() {
                            store.settings = previous
                            failure = store.errorMessage ?? "Couldn’t save the search provider selection."
                        }
                    }
                    .disabled(changed || !readiness.isReady || store.settings.searchProviderID == draft.id)
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshProviderHealth(providerID: draft.id) }
    }

    private func pathRow(_ title: String, keyPath: WritableKeyPath<LocalSearchConfiguration, URL?>, directory: Bool)
        -> some View
    {
        HStack {
            LabeledContent(title) {
                Text(draft.localSearch?[keyPath: keyPath]?.path ?? "Not Selected")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(draft.localSearch?[keyPath: keyPath]?.path ?? "Choose a path on this Mac")
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.title = title
                panel.canChooseDirectories = directory
                panel.canChooseFiles = !directory
                panel.allowsMultipleSelection = false
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    var configuration = draft.localSearch ?? LocalSearchConfiguration()
                    configuration[keyPath: keyPath] = url
                    draft.localSearch = configuration
                }
            }.accessibilityLabel("Choose \(title)")
        }
    }

    private func save() {
        guard let index = store.settings.serviceProviders.firstIndex(where: { $0.id == draft.id }) else { return }
        let previous = store.settings
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.serviceProviders[index] = draft
        guard store.saveSettings() else {
            store.settings = previous
            failure = store.errorMessage ?? "Couldn’t save provider settings."
            return
        }
        drafts.clear(draft.id)
        failure = nil
        Task { await store.refreshProviderHealth(providerID: draft.id) }
    }
}

struct SearchModePicker: View {
    @Binding var selection: SearchMode
    var body: some View {
        Picker("Search Mode", selection: $selection) {
            Text("Text").tag(SearchMode.text)
            Text("Voice").tag(SearchMode.voice)
            Text("Fusion").tag(SearchMode.fusion)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Text searches written content. Voice searches recorded audio. Fusion combines their ranked results.")
    }
}

struct LibraryTextSearchProviderView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var status: LibraryDataStatus
    var body: some View {
        Form {
            Section {
                Label("Library Text Search", systemImage: "text.magnifyingglass").font(.title2.weight(.semibold))
                Text(
                    "Searches meeting titles, notes, summaries, and transcripts on this Mac. No model or service account is required."
                )
            }
            Section("Index") {
                Text("Text search updates as saved meeting content changes. Rebuilding reads the library files again.")
                Button("Rebuild Text Index") { store.libraryMonitor?.rebuild() }
                    .disabled(status.isBuilding || store.isChangingLibrary || !store.libraryWritable)
            }
        }.formStyle(.grouped)
    }
}
