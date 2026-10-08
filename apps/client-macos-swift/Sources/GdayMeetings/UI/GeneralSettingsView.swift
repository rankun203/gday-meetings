import SwiftUI

/// Behavior and provider choices share one scrolling surface.
struct GeneralSettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @ObservedObject private var health = ProviderHealthStore.shared
    @ObservedObject private var models = LocalModelManager.shared
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("displaySummaryTitleOnMeetings") private var displaySummaryTitleOnMeetings = true
    @ViewState private var previewScenario = UIPreview.generalScenario ?? 1

    private var audioSettingsLocked: Bool {
        store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording
    }

    private func setting<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: path] },
            set: {
                store.settings[keyPath: path] = $0
                if let boolPath = path as? WritableKeyPath<AppSettings, Bool>, let enabled = $0 as? Bool {
                    store.settings.recordExplicitFeatureChoice(boolPath, enabled: enabled)
                }
                store.saveSettings()
            })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if UIPreview.enabled, UIPreview.generalScenario != nil {
                    Picker("Preview Scenario", selection: $previewScenario) {
                        ForEach(1...10, id: \.self) { Text("Scenario \($0)").tag($0) }
                    }
                    .onChange(of: previewScenario) { _, value in
                        UIPreview.configureGeneralScenario(store, scenario: value)
                    }
                    .padding(.horizontal, 20)
                }
                HStack(alignment: .top, spacing: AppTheme.sectionSpacing) {
                    VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                        group("Record") {
                            switchRow("Microphone", enabled: setting(\.captureMicrophone))
                            switchRow("System Audio", enabled: setting(\.captureSystemAudio))
                            Picker("Audio Format", selection: setting(\.recordingFormat)) {
                                Text("Opus").tag(RecordingFormat.opus)
                                Text("M4A (AAC)").tag(RecordingFormat.m4a)
                                Text("WAV").tag(RecordingFormat.wav)
                            }
                            switchRow(
                                "Automatically Process Microphone Audio", enabled: setting(\.automaticVoiceProcessing))
                            Text("Reduces echo and background noise when needed. May lower other apps’ volume.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.disabled(audioSettingsLocked)
                        group("Recording") {
                            feature(
                                "Automatically Transcribe", enabled: setting(\.showLiveTranscript),
                                capability: .liveTranscription, provider: store.settings.liveTranscriptionProviderID)
                            Text("Speaker labels are added after recording.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        group("After Recording") {
                            feature(
                                "Automatically Transcribe", enabled: setting(\.autoTranscribe),
                                capability: .transcription, provider: store.settings.transcriptionProviderID)
                            if store.settings.autoTranscribe {
                                switchRow(
                                    "Automatically Replace Live Transcripts",
                                    enabled: setting(\.autoTranscribeEvenWithLiveTranscript)
                                )
                                .font(.callout).padding(.leading, 16)
                            }
                            feature(
                                "Automatically Diarize", enabled: setting(\.labelRecordedSpeakers),
                                capability: .diarization, provider: store.settings.diarizationProviderID,
                                prerequisite: recordedLabelingPrerequisite)
                            feature(
                                "Automatically Associate People", enabled: setting(\.recognizeSpeakers), status: .ready)
                            feature(
                                "Automatically Summarize", enabled: setting(\.autoSummarize),
                                capability: .summarization, provider: store.settings.summaryProviderID)
                            feature(
                                "Automatically Extract To-Dos", enabled: setting(\.autoExtractTodos),
                                capability: .summarization, provider: store.settings.summaryProviderID,
                                prerequisite: store.settings.autoSummarize ? nil : "Turn on Automatically Summarize.")
                            Text("Extracts to-dos from completed summaries.").font(.caption).foregroundStyle(.secondary)
                        }
                        group("General") {
                            Picker("Appearance", selection: $appearance.selection) {
                                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            switchRow(
                                "Display Summary Title on Meetings", enabled: $displaySummaryTitleOnMeetings)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                        group("Capability Providers") {
                            provider(
                                "Live Transcription", capability: .liveTranscription,
                                selected: store.settings.liveTranscriptionProviderID)
                            provider(
                                "Recorded Transcription", capability: .transcription,
                                selected: store.settings.transcriptionProviderID)
                            provider(
                                "Speaker Diarization", capability: .diarization,
                                selected: store.settings.diarizationProviderID)
                            provider(
                                "Summarization", capability: .summarization, selected: store.settings.summaryProviderID)
                            provider("Search", capability: .search, selected: store.settings.searchProviderID)
                            Button("Configure Capability Providers") { settingsTab = "providers" }
                                .buttonStyle(.link).font(.callout)
                        }
                        group("Transcription Language") {
                            MeetingLanguagePicker(title: "Language", selection: setting(\.defaultLanguage))
                        }
                        Text(
                            "Speaker diarization distinguishes voices. Speaker association matches them to the People Library."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.toggleStyle(.switch).padding(AppTheme.contentInset)
            }
        }
        .task(id: healthFingerprint) { await health.checkSelected(settings: store.settings) }
        .task(id: LocalHealthIdentity(settings: healthFingerprint, phases: models.states.mapValues(\.phase))) {
            await store.refreshLocalProviderHealth()
        }
        .background(
            ProviderPanelWindowObserver {
                Task { await health.checkSelected(settings: store.settings) }
            })
    }

    private var recordedLabelingPrerequisite: String? {
        guard
            let provider = store.settings.serviceProviders.first(where: {
                $0.id == store.settings.diarizationProviderID
            }),
            provider.kind == .runpod || provider.kind == .gdayWebsite
        else { return nil }
        guard store.settings.autoTranscribe else { return "Turn on Automatically Transcribe." }
        guard store.settings.transcriptionProviderID == provider.id else {
            return "Choose the same provider for Recorded Transcription and Speaker Diarization."
        }
        return nil
    }

    private struct HealthIdentity: Equatable {
        let configuration: ProviderHealthStore.Configuration
        let selections: [UUID?]
    }

    private struct LocalHealthIdentity: Equatable {
        let settings: HealthIdentity
        let phases: [LocalModelID: LocalModelPhase]
    }

    private var healthFingerprint: HealthIdentity {
        HealthIdentity(
            configuration: .init(store.settings),
            selections: [
                store.settings.liveTranscriptionProviderID,
                store.settings.transcriptionProviderID,
                store.settings.diarizationProviderID, store.settings.summaryProviderID, store.settings.searchProviderID,
            ])
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: AppTheme.contentSpacing, content: content)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(AppContentSurface())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func feature(
        _ title: String, enabled: Binding<Bool>, capability: ProviderCapability,
        provider: UUID?, prerequisite: String? = nil
    ) -> some View {
        let status: ProviderHealth =
            provider.map { health.state(providerID: $0, capability: capability) }
            ?? .notReady("Choose a provider.")
        return feature(title, enabled: enabled, status: status, prerequisite: prerequisite)
    }

    private func feature(
        _ title: String, enabled: Binding<Bool>, status: ProviderHealth, prerequisite: String? = nil
    ) -> some View {
        let reason = prerequisite ?? status.reason
        let ready = prerequisite == nil && status.isReady
        return VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
            HStack(alignment: .top, spacing: AppTheme.contentSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    if enabled.wrappedValue {
                        Label(
                            prerequisite == nil ? status.title : "Not Ready",
                            systemImage: ready
                                ? "checkmark.circle" : reason == nil ? "clock" : "exclamationmark.circle"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    else {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Toggle(title, isOn: enabled).labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityHint(enabled.wrappedValue ? (reason ?? status.title) : "Off")
            }
            if enabled.wrappedValue, let reason {
                AppInlineMessage(text: reason, systemImage: "exclamationmark.circle", tint: .orange)
            }
        }
    }

    private func switchRow(_ title: String, enabled: Binding<Bool>) -> some View {
        HStack {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle(title, isOn: enabled).labelsHidden().accessibilityLabel(title)
        }
    }

    private func provider(_ title: String, capability: ProviderCapability, selected: UUID?) -> some View {
        GeneralProviderPicker(
            title: title, capability: capability,
            selection: Binding(
                get: { selected },
                set: {
                    store.settings.selectProvider($0, for: capability)
                    store.saveSettings()
                }))
    }
}

/// A dropdown checks all candidates only while open and shows each result as it arrives.
private struct GeneralProviderPicker: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var health = ProviderHealthStore.shared
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Binding var selection: UUID?
    @ViewState private var isOpen = false
    let title: String
    let capability: ProviderCapability

    init(title: String, capability: ProviderCapability, selection: Binding<UUID?>) {
        self.title = title
        self.capability = capability
        _selection = selection
    }

    private var candidates: [(id: UUID, name: String)] {
        var result = store.settings.serviceProviders.filter { $0.kind.capabilities.contains(capability) }
            .map { (id: $0.id, name: $0.name) }
        if ThisMacProvider.capabilities.contains(capability) { result.insert((ThisMacProvider.id, "This Mac"), at: 0) }
        return result
    }
    private var selectedName: String {
        guard let selection else { return "None" }
        return candidates.first { $0.id == selection }?.name ?? "Provider Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout)
            Button {
                isOpen.toggle()
            } label: {
                HStack {
                    Text(selectedName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }.frame(maxWidth: .infinity)
            }
            .accessibilityLabel(title).accessibilityValue(selectedName)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    candidate(id: nil, name: "None", state: .ready)
                    ForEach(candidates, id: \.id) { candidate in
                        self.candidate(
                            id: candidate.id, name: candidate.name,
                            state: health.state(providerID: candidate.id, capability: capability))
                    }
                }.padding(8).frame(minWidth: 290)
                    .task { await health.checkEligible(capability: capability, settings: store.settings) }
            }
            if let selection {
                let status = health.state(providerID: selection, capability: capability)
                if let reason = status.reason {
                    AppInlineMessage(text: reason, systemImage: "exclamationmark.circle", tint: .orange)
                    Button("Open \(selectedName) Settings") {
                        health.settingsProviderID = selection
                        settingsTab = "providers"
                    }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func candidate(id: UUID?, name: String, state: ProviderHealth) -> some View {
        Button {
            selection = id
            isOpen = false
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: selection == id ? "checkmark" : "circle").opacity(selection == id ? 1 : 0)
                Text(state.isReady ? name : "\(name) (\(state.reason ?? state.title))")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }.padding(5).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!state.isReady)
    }
}
