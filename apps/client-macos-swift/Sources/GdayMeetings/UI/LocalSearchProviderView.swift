import AppKit
import SwiftUI

struct LocalSearchProviderView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var drafts: ProviderDraftCoordinator
    @ObservedObject private var health = ProviderHealthStore.shared
    @ObservedObject private var localModels = LocalModelManager.shared
    @Binding var draft: ServiceProvider
    @ViewState private var failure: String?

    private var changed: Bool { store.settings.serviceProviders.first { $0.id == draft.id } != draft }
    private var readiness: ProviderHealth { health.validationState(providerID: draft.id, capability: .search) }

    var body: some View {
        Form {
            Section {
                Label(draft.kind.title, systemImage: draft.kind.systemImage).font(.title2.weight(.semibold))
                TextField("Name", text: $draft.name)
                Toggle("Enable This Provider", isOn: $draft.isEnabled)
                Text(
                    "Searches meeting titles, notes, summaries, and transcripts by meaning on this Mac."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Search Model") {
                Picker("Model", selection: modelBinding) {
                    ForEach(SemanticModelID.allCases) { model in Text(model.title).tag(model) }
                }
                LocalModelDownloadView(modelID: configuration.selectedModel.localID)
                Text("Changing models builds a separate search index. Progress appears in Data and Tasks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Ranking") {
                LabeledContent(
                    "Speaker Match Boost", value: configuration.boost.formatted(.number.precision(.fractionLength(2))))
                Slider(value: boostBinding, in: 0...0.2, step: 0.01) { Text("Speaker Match Boost") }.labelsHidden()
                Text(
                    "Ranks passages higher when identified people in your query speak in them. Set to 0 to rank by content similarity only."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Readiness") {
                ProviderHealthSummary(title: "Search", health: readiness)
                Button("Refresh") { Task { await store.refreshProviderHealth(providerID: draft.id) } }
                    .disabled(changed)
            }
            Section {
                if let failure { AppInlineMessage(text: failure, systemImage: "exclamationmark.circle", tint: .orange) }
                HStack {
                    Button("Save", action: save)
                        .disabled(!changed || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(
                        store.settings.searchProviderID == draft.id
                            ? "Selected for Search" : "Use for Search"
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
        .task(id: localModels.state(for: configuration.selectedModel.localID).healthIdentity) {
            await store.refreshProviderHealth(providerID: draft.id)
            store.searchConfigurationChanged()
        }
    }

    private var configuration: LocalSearchConfiguration { draft.localSearch ?? .init() }
    private var modelBinding: Binding<SemanticModelID> {
        Binding(
            get: { configuration.selectedModel },
            set: { value in
                var next = configuration
                next.semanticModel = value
                draft.localSearch = next
            })
    }
    private var boostBinding: Binding<Double> {
        Binding(
            get: { configuration.boost },
            set: { value in
                var next = configuration
                next.speakerMatchBoost = value
                draft.localSearch = next
            })
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
            Text("Semantic").tag(SearchMode.semantic)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Text matches words. Semantic searches by meaning with the selected model.")
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
