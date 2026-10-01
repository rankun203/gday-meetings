import SwiftUI

/// Defaults group live and saved work by transcription and speaker recognition.
struct DefaultsSettingsView: View {
    @EnvironmentObject private var store: MeetingStore

    @AppStorage("settingsTab") private var settingsTab = "defaults"

    // Capture reads these when a recording starts; changing them mid-recording
    // would misdescribe the recording in progress.
    private var audioSettingsLocked: Bool {
        store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording
    }

    private func setting<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: path] },
            set: {
                store.settings[keyPath: path] = $0
                store.saveSettings()
            })
    }

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Microphone", isOn: setting(\.captureMicrophone)).disabled(audioSettingsLocked)
                Toggle("System Audio", isOn: setting(\.captureSystemAudio)).disabled(audioSettingsLocked)
                // HIG Privacy: explain the requested resources in the context of their use.
                // https://developer.apple.com/design/human-interface-guidelines/privacy
                Text(
                    "New Recording starts with these sources, and you can change them there. macOS asks for permission the first time you record each source."
                ).font(.caption).foregroundStyle(.secondary)
                Picker("Audio Format", selection: setting(\.recordingFormat)) {
                    Text("Opus (Recommended)").tag(RecordingFormat.opus)
                    Text("M4A (AAC)").tag(RecordingFormat.m4a)
                    Text("WAV").tag(RecordingFormat.wav)
                }.disabled(audioSettingsLocked)
                Text(
                    "Recordings are saved in this format when you stop. If conversion fails, the original audio is kept."
                ).font(.caption).foregroundStyle(.secondary)
                Toggle("Turn On Voice Processing Automatically", isOn: setting(\.automaticVoiceProcessing))
                    .disabled(audioSettingsLocked)
                Text(
                    "Turns on when audio plays through speakers or the microphone picks up system audio. Reduces echo and background noise in the microphone track, and may lower other apps’ volume."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription") {
                Picker("Live Provider", selection: setting(\.liveTranscriptionProviderID)) {
                    Text("None").tag(nil as UUID?)
                    if store.settings.thisMacCapabilities.contains(.liveTranscription) {
                        Text("This Mac").tag(Optional(ThisMacProvider.id))
                    }
                    else if let selected = store.settings.liveTranscriptionProviderID {
                        Text("Provider Unavailable").tag(Optional(selected))
                    }
                }
                if !store.settings.thisMacCapabilities.contains(.liveTranscription) {
                    Text("Turn on Live Transcription for This Mac in Service Providers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show Live Transcript", isOn: setting(\.showLiveTranscript))
                CapabilityProviderRows(
                    title: "Recorded Audio Provider", capability: .transcription,
                    selection: setting(\.transcriptionProviderID))
                MeetingLanguagePicker(title: "Default Language", selection: setting(\.defaultLanguage))
                Toggle("Automatically Transcribe", isOn: setting(\.autoTranscribe))
                    .toggleStyle(.checkbox)
                if store.settings.autoTranscribe {
                    Toggle(
                        "Automatically Transcribe Even if a Live Transcript Exists",
                        isOn: setting(\.autoTranscribeEvenWithLiveTranscript)
                    )
                    .toggleStyle(.checkbox)
                    .padding(.leading, 20)
                }
                Text(
                    "Live transcription runs on this Mac. Recorded audio is sent to its selected transcription provider."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Open Service Providers") { settingsTab = "providers" }
            }
            Section("Speaker Recognition") {
                Toggle("During Recording", isOn: setting(\.liveSpeakerRecognitionEnabled))
                CapabilityProviderRows(
                    title: "Live Provider", capability: .liveDiarization,
                    selection: setting(\.liveDiarizationProviderID))
                Toggle("After Recording", isOn: setting(\.recognizeSpeakers))
                CapabilityProviderRows(
                    title: "Recorded Audio Provider", capability: .diarization,
                    selection: setting(\.diarizationProviderID))
                CapabilityProviderRows(
                    title: "Voice Matching Provider", capability: .speakerRecognition,
                    selection: setting(\.speakerRecognitionProviderID))
                Text("Shows names when voices match people. Other voices keep anonymous speaker labels.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Service Providers") { settingsTab = "providers" }
            }
            CapabilityDefaultSection(
                capability: .summarization, selection: setting(\.summaryProviderID)
            ) {
                Toggle("Automatically Summarize", isOn: setting(\.autoSummarize))
                    .toggleStyle(.checkbox)
                Toggle("Automatically Extract To-Dos", isOn: setting(\.autoExtractTodos))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// A provider picker for one capability, followed by capability-specific
/// settings and the caption that states what the provider receives.
struct CapabilityDefaultSection<Extra: View>: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var localModels = LocalModelManager.shared
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    let capability: ProviderCapability
    @Binding var selection: UUID?
    let caption: String?
    @ViewBuilder var extra: Extra

    init(
        capability: ProviderCapability, selection: Binding<UUID?>, caption: String? = nil,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.capability = capability
        _selection = selection
        self.caption = caption
        self.extra = extra()
    }

    private var eligible: [ServiceProvider] {
        store.settings.serviceProviders.filter {
            (capability != .diarization || $0.kind == .community1)
                && ProviderConfigurationEligibility.canSelect(
                    $0, for: capability, providers: store.settings.serviceProviders)
        }
    }

    var body: some View {
        Section(capability.title) {
            let eligible = eligible
            // Keep the picker while a saved choice exists so it can be cleared,
            // even after its provider stops qualifying.
            if !eligible.isEmpty || selection != nil {
                Picker("Provider", selection: $selection) {
                    Text("None").tag(nil as UUID?)
                    ForEach(eligible) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                    if let selected = selection, !eligible.contains(where: { $0.id == selected }) {
                        Text("Provider Unavailable").tag(Optional(selected))
                    }
                }
            }
            // HIG Writing: give an empty state a useful next action.
            if eligible.isEmpty {
                HStack {
                    Text("Add a provider and turn on \(capability.title) to choose it here.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Service Providers") { settingsTab = "providers" }
                }
            }
            extra
            if let provider = eligible.first(where: { $0.id == selection }), provider.kind.isLocal,
                let model = capability == .speakerRecognition
                    ? LocalModelID.voiceEmbedding : LocalModelID(rawValue: provider.model),
                localModels.state(for: model).phase != .ready
            {
                HStack {
                    Text(localModels.state(for: model).phase.settingsTitle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Service Providers") { settingsTab = "providers" }
                }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Provider selection and readiness within a shared settings section.
struct CapabilityProviderRows: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var localModels = LocalModelManager.shared
    let title: String
    let capability: ProviderCapability
    @Binding var selection: UUID?

    private var eligible: [ServiceProvider] {
        store.settings.serviceProviders.filter {
            (capability != .diarization || $0.kind == .community1)
                && ProviderConfigurationEligibility.canSelect(
                    $0, for: capability, providers: store.settings.serviceProviders)
        }
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(nil as UUID?)
            ForEach(eligible) { provider in
                Text(provider.name).tag(Optional(provider.id))
            }
            if let selected = selection, !eligible.contains(where: { $0.id == selected }) {
                Text("Provider Unavailable").tag(Optional(selected))
            }
        }
        if let provider = eligible.first(where: { $0.id == selection }), provider.kind.isLocal,
            let model = capability == .speakerRecognition
                ? LocalModelID.voiceEmbedding : LocalModelID(rawValue: provider.model),
            localModels.state(for: model).phase != .ready
        {
            Text("\(title): \(localModels.state(for: model).phase.settingsTitle)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
