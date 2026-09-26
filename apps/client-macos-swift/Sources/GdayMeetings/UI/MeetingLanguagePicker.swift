import SwiftUI

/// Language choices come from the selected transcription provider: RunPod's list is
/// built in, and a website's list is saved after the person chooses Load Languages.
/// Showing the picker never contacts the provider. Retaining the stored value keeps offline recording independent of service availability.
struct MeetingLanguagePicker: View {
    @EnvironmentObject private var store: MeetingStore
    var title = "Language"
    @Binding var selection: String
    var providerID: UUID?
    var compact = false
    @ViewState private var showInformation = false

    private var selectedProviderID: UUID? { providerID ?? store.settings.transcriptionProviderID }
    private var provider: ServiceProvider? {
        store.settings.serviceProviders.first { $0.id == selectedProviderID }
    }
    private var state: ProviderLanguageState { store.languageState(for: selectedProviderID) }
    private var languages: [ProviderLanguage] {
        switch state {
        case .builtIn(let catalog), .loaded(let catalog, _): catalog.languages
        case .idle, .loading, .failed: []
        }
    }
    private var selectedName: String {
        guard TranscriptionLanguage.isExplicit(selection) else { return "Choose a Language" }
        return languages.first { $0.code == selection }?.name
            ?? Locale.current.localizedString(forIdentifier: selection) ?? selection
    }
    private var unsupported: Bool {
        guard !languages.isEmpty, TranscriptionLanguage.isExplicit(selection) else { return false }
        return !languages.contains { $0.code == selection }
    }

    var body: some View {
        HStack(spacing: 4) {
            if compact {
                languagePicker.labelsHidden().frame(width: 120)
            }
            else {
                languagePicker
            }
            Button {
                showInformation.toggle()
            } label: {
                Image(systemName: informationSymbol)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Language Information")
            .help("About transcription language")
            .popover(isPresented: $showInformation) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Language").font(.headline)
                    Text("Choose the language spoken in this meeting.")
                    status
                }
                .font(.callout)
                .padding(16)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var informationSymbol: String {
        if case .failed = state { return "exclamationmark.circle" }
        return "info.circle"
    }

    private var languagePicker: some View {
        Picker(title, selection: $selection) {
            ForEach(languages) { language in
                Text(language.name).tag(language.code)
            }
            if !languages.contains(where: { $0.code == selection }) {
                Text(unsupported ? "\(selectedName) (Unsupported)" : selectedName)
                    .tag(selection)
                    .disabled(true)
            }
        }
        .pickerStyle(.menu)
        .disabled(languages.isEmpty)
    }

    @ViewBuilder private var status: some View {
        if let provider {
            switch state {
            case .idle:
                if provider.supports(.transcription) {
                    Text("Languages for \(provider.name) aren’t loaded.")
                        .font(.caption).foregroundStyle(.secondary)
                    loadButton(provider)
                }
                else {
                    Text(
                        provider.isEnabled
                            ? "Turn on Transcription for \(provider.name) in Settings → Service Providers to load its languages."
                            : "\(provider.name) is disabled. Turn it on in Settings → Service Providers to load its languages."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            // Whenever the menu has choices, name the provider they come from.
            case .builtIn:
                Text("Languages from \(provider.name), included with Gday Meetings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading:
                Text("Loading Languages…").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Languages Unavailable", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                loadButton(provider)
            case .loaded(_, let fetchedAt):
                Text(
                    "Languages from \(provider.name), updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                loadButton(provider)
            }
        }
        else {
            Text("Select a transcription provider in Settings to change the language.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The only place a picker contacts a provider, and only when chosen.
    @ViewBuilder private func loadButton(_ provider: ServiceProvider) -> some View {
        Button("Load Languages") {
            Task { await store.refreshProviderLanguages(providerID: provider.id) }
        }
        .font(.caption)
        .disabled(!provider.supports(.transcription))
    }
}
