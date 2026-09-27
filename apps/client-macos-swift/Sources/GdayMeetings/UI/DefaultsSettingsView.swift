import SwiftUI

/// Settings → Defaults: what new recordings start with, then one section per
/// capability that chooses the provider used for new work. Add a capability by
/// adding one `CapabilityDefaultSection` with its settings key path; stored keys
/// stay in `AppSettings`.
struct DefaultsSettingsView: View {
    @EnvironmentObject private var store: MeetingStore

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
            Section("Live Transcription") {
                LabeledContent("Provider", value: "This Mac")
                Toggle("Show Live Transcript", isOn: setting(\.showLiveTranscript))
                Text(
                    "Transcribes audio on this Mac and shows text in Transcript while recording. Requires macOS 26 or later and a supported speech model."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            CapabilityDefaultSection(
                capability: .transcription, selection: setting(\.transcriptionProviderID),
                caption: "Transcription sends recording audio to the selected provider."
            ) {
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
            }
            CapabilityDefaultSection(
                capability: .summarization, selection: setting(\.summaryProviderID),
                caption: "Summaries and chat send the selected transcript and notes to this provider."
            ) {
                Toggle("Automatically Summarize", isOn: setting(\.autoSummarize))
                    .toggleStyle(.checkbox)
                Text(
                    "Generates a summary after a live transcript is saved or transcription finishes. If both finish, each generates a summary."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A provider picker for one capability, followed by capability-specific
/// settings and the caption that states what the provider receives.
struct CapabilityDefaultSection<Extra: View>: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    let capability: ProviderCapability
    @Binding var selection: UUID?
    let caption: String
    @ViewBuilder var extra: Extra

    init(
        capability: ProviderCapability, selection: Binding<UUID?>, caption: String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.capability = capability
        _selection = selection
        self.caption = caption
        self.extra = extra()
    }

    private var eligible: [ServiceProvider] {
        store.settings.serviceProviders.filter {
            ProviderConfigurationEligibility.canSelect($0, for: capability, providers: store.settings.serviceProviders)
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
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
