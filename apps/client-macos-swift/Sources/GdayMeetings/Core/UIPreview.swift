import AVFoundation
import Foundation
import SwiftUI

/// Uses a temporary library, silent playback, and no Keychain access.
enum UIPreview {
    static let enabled =
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
        || Bundle.main.object(forInfoDictionaryKey: "GdayUIPreview") as? Bool == true

    @MainActor static func makeStore() -> MeetingStore {
        guard enabled else { return MeetingStore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Gday-UI-Preview-\(UUID())")
        let store = MeetingStore(dataDirectory: directory)
        do {
            for title in ["Synthetic single track", "Synthetic conversation"] {
                var meeting = Meeting(title: title)
                let folder = store.directory(for: meeting.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                meeting.audioFiles = title.contains("single") ? ["microphone.wav"] : ["microphone.wav", "system.wav"]
                meeting.duration = 60
                for (index, name) in meeting.audioFiles.enumerated() {
                    try writeFixture(to: folder.appendingPathComponent(name), source: index)
                }
                try store.insertImportedMeeting(meeting)
                try writeArchiveFixture(store: store, id: meeting.id, verified: title.contains("single"))
            }
            let person = store.addPerson(name: "Alex Morgan")
            let suggested = store.addPerson(name: "Sam Chen")
            let previewTag = store.addTag(name: "Preview")
            let projectTag = store.addTag(name: "Planning")
            if var conversation = store.meetings.first(where: { $0.title == "Synthetic conversation" }) {
                let first = MeetingSpeaker(
                    label: "sys_SPEAKER_00", track: "system", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [1, 0], personID: person, confirmed: true)
                let second = MeetingSpeaker(
                    label: "sys_SPEAKER_01", track: "system", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [0, 1], personID: suggested, confidence: 0.91)
                let third = MeetingSpeaker(
                    label: "mic_SPEAKER_00", track: "microphone", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [0.5, 0.5])
                conversation.replaceSpeakers([first, second, third])
                conversation.tagIDs = [previewTag, projectTag]
                conversation.notes = """
                    # Release plan <!-- gday:t=0:05 -->

                    - Review **meeting notes** <!-- gday:t=0:12 -->
                    - [ ] Update the schedule <!-- gday:t=0:24 -->

                    This line has no recording time.
                    """
                conversation.transcript = [
                    TranscriptSegment(
                        start: 1, end: 5, speaker: first.label,
                        text: "Let’s review the release plan.", speakerID: first.id),
                    TranscriptSegment(
                        start: 6, end: 10, speaker: second.label,
                        text: "The next step is to check the meeting notes.", speakerID: second.id),
                    TranscriptSegment(
                        start: 11, end: 15, speaker: third.label,
                        text: "I’ll update the schedule after this call.", speakerID: third.id),
                ]
                store.updateMeeting(conversation)
                var live = LiveTranscriptDraft(meetingID: conversation.id, locale: "en-AU")
                live.accept(
                    .init(
                        session: UUID(), source: .system, start: 1, end: 4,
                        text: "Synthetic live draft for reviewing transcript revisions.", locale: "en-AU"))
                live.complete = true
                try live.save(at: store.directory(for: conversation.id))
                if ProcessInfo.processInfo.arguments.contains("--synthetic-live-recording") {
                    // Simulate a new recording, not a live stream on top of the
                    // saved batch fixture. Stop can then exercise live adoption.
                    if var recording = store.meetings.first(where: { $0.id == conversation.id }) {
                        recording.transcript = []
                        recording.replaceSpeakers([])
                        store.updateMeeting(recording)
                    }
                    store.recordingID = conversation.id
                    store.recordingStartedAt = Date()
                    store.recordingMeter.deliver(
                        RecordingLevels(
                            microphone: RecordingSourceLevel(enabled: true, hasSamples: true),
                            system: RecordingSourceLevel(enabled: true, hasSamples: true),
                            microphoneStatus: RecordingMicrophoneStatus(voiceProcessing: true, canSwitch: true)))
                    store.liveTranscript.seedPreview(
                        meetingID: conversation.id, directory: store.directory(for: conversation.id))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--synthetic-providers") {
                store.settings = syntheticProviderSettings(store.settings)
            }
            if ProcessInfo.processInfo.arguments.contains("--synthetic-multiple-transcription-providers") {
                store.settings = syntheticProviderSettings(store.settings)
                var second = ServiceProvider(kind: .runpod)
                second.name = "Second Preview Provider"
                second.endpoint = "https://second.example.invalid/v2/preview"
                second.apiKey = "synthetic-preview-key"
                second.enabledCapabilities = [.transcription]
                second.uploadProviderID = store.settings.serviceProviders.first { $0.kind == .filedrop }?.id
                store.settings.serviceProviders.append(second)
            }
            if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--provider-test-env") {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.indices.contains(flag + 1), !arguments[flag + 1].hasPrefix("--") else {
                    throw ServiceError("Add the configuration file path after --provider-test-env.")
                }
                let contents: String
                do { contents = try String(contentsOfFile: arguments[flag + 1], encoding: .utf8) }
                catch { throw ServiceError("Couldn’t read the provider test configuration file.") }
                let providers = try testProviders(configuration: contents)
                store.settings.serviceProviders = providers
                store.settings.transcriptionProviderID = providers.first { $0.kind == .runpod }?.id
            }
        }
        catch { store.errorMessage = "Could not prepare UI Preview: \(error.localizedDescription)" }
        return store
    }

    /// Parses only the explicitly supplied test file. Values are never logged or
    /// passed through a shell, and provider API keys stay in memory in Preview.
    static func testProviders(configuration: String) throws -> [ServiceProvider] {
        var values: [String: String] = [:]
        for line in configuration.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first,
                first == "\"" || first == "'", value.last == first
            {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw ServiceError("Add \(key) to the provider test configuration file.")
            }
            return value
        }
        var filedrop = ServiceProvider(kind: .filedrop)
        filedrop.endpoint = try required("FILE_DROP_URL")
        filedrop.apiKey = try required("FILE_DROP_API_KEY")
        filedrop.enabledCapabilities = [.fileTransfer]
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = try required("RUNPOD_ENDPOINT_URL")
        runpod.apiKey = try required("RUNPOD_API_KEY")
        runpod.enabledCapabilities = [.transcription, .diarization]
        runpod.uploadProviderID = filedrop.id
        return [runpod, filedrop]
    }

    /// Fills Settings → Data Privacy and provider panels without real services.
    /// `.invalid` hosts never resolve (RFC 6761), so a connection check started by
    /// opening a provider panel fails locally and no content can be uploaded.
    static func syntheticProviderSettings(_ base: AppSettings) -> AppSettings {
        var settings = base
        var filedrop = ServiceProvider(kind: .filedrop)
        filedrop.endpoint = "https://files.example.invalid"
        filedrop.apiKey = "synthetic-preview-key"
        filedrop.enabledCapabilities = [.fileTransfer]
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = "https://api.runpod.example.invalid/v2/preview"
        runpod.apiKey = "synthetic-preview-key"
        runpod.enabledCapabilities = [.transcription, .diarization]
        runpod.uploadProviderID = filedrop.id
        var llm = ServiceProvider(kind: .openAICompatible)
        llm.name = "Preview LLM"
        llm.endpoint = "https://llm.example.invalid/v1"
        llm.model = "preview-model"
        llm.enabledCapabilities = [.summarization]
        settings.serviceProviders = [runpod, filedrop, llm]
        settings.transcriptionProviderID = runpod.id
        settings.summaryProviderID = llm.id
        settings.autoTranscribe = true
        return settings
    }

    /// Shows the archived and incomplete states. The `.invalid` origin never
    /// resolves, and Preview cannot sign in, so Archive to Server stays disabled.
    @MainActor static func writeArchiveFixture(store: MeetingStore, id: UUID, verified: Bool) throws {
        let checkpoint = ArchiveCheckpoint(
            origin: "https://meetings.example.invalid", externalID: id.uuidString, importKey: "preview",
            snapshot: Data("{}".utf8),
            audio: [ArchiveAudio(filename: "microphone.wav", path: "microphone.wav", sha256: "", size: 0)],
            verifiedAt: verified ? Date() : nil)
        try JSONEncoder().encode(checkpoint).write(to: store.archiveCheckpointURL(for: id), options: .atomic)
        store.refreshArchiveStatus(id: id)
    }

    static func writeFixture(to url: URL, source: Int) throws {
        let rate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        for second in 0..<60 {
            let samples = buffer.floatChannelData![0]
            for frame in 0..<8000 {
                let time = Double(second) + Double(frame) / rate
                let phase = (time + Double(source) * 4).truncatingRemainder(dividingBy: 12)
                let envelope = phase > 1 && phase < 7 ? pow(sin((phase - 1) / 6 * .pi), 2) : 0
                samples[frame] = Float(0.65 * envelope * sin(2 * .pi * 230 * time) * (0.65 + 0.35 * sin(time * 13)))
            }
            try file.write(from: buffer)
        }
    }
}

struct PreviewContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewState private var appearance = 0
    @ViewState private var previewVoiceProcessing = false
    private static func recordingLevel(at time: Double, offset: Double, reconnects: Bool = false)
        -> RecordingSourceLevel
    {
        let phase = (time + offset).truncatingRemainder(dividingBy: 7)
        let value = phase < 4 ? abs(sin(time * 5 + offset)) * 0.65 + 0.12 : 0
        // Simulate a 4-second device switch every 20 seconds to show that state:
        // 2 seconds without a replacement device, then 2 seconds switching to one.
        let cycle = time.truncatingRemainder(dividingBy: 20)
        let reconnecting = reconnects && cycle >= 16
        return RecordingSourceLevel(
            enabled: true, hasSamples: true, reconnecting: reconnecting,
            switchingTo: reconnecting && cycle >= 18 ? "Preview Headphones" : nil, rmsDB: value * 60 - 60)
    }
    private static func recordingHistory(at time: Double) -> RecordingActivityHistory {
        var history = RecordingActivityHistory()
        let tick = floor(time * 10)
        for index in 0..<102 {
            let sampleTime = (tick - Double(101 - index)) / 10
            history.append(
                RecordingLevels(
                    microphone: recordingLevel(at: sampleTime, offset: 0),
                    system: recordingLevel(at: sampleTime, offset: 3, reconnects: true)), at: sampleTime)
        }
        return history
    }
    var body: some View {
        VStack(spacing: 0) {
            if UIPreview.enabled {
                HStack {
                    Label("UI Preview · Synthetic audio · Silent playback", systemImage: "eye")
                    Spacer()
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }.fixedSize()
                }.font(.caption).padding(8).background(.quaternary)
            }
            if UIPreview.enabled {
                DisclosureGroup("Recording visualization preview · synthetic levels") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let now = ProcessInfo.processInfo.systemUptime
                        let history = Self.recordingHistory(at: now)
                        let status = RecordingWorkspaceView.reconnectingStatus(
                            RecordingLevels(
                                microphone: Self.recordingLevel(at: now, offset: 0),
                                system: Self.recordingLevel(at: now, offset: 3, reconnects: true)))
                        VStack(alignment: .leading, spacing: 10) {
                            // Reserve the line so the simulated reconnect does not shift the meters.
                            Label(status ?? "Reconnecting system audio…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline).foregroundStyle(.secondary).opacity(status == nil ? 0 : 1)
                                .accessibilityHidden(status == nil)
                            HStack(alignment: .top, spacing: 26) {
                                VStack(alignment: .leading, spacing: 10) {
                                    RecordingSourceMeter(
                                        title: "Microphone", symbol: "mic.fill",
                                        source: Self.recordingLevel(
                                            at: now, offset: 0),
                                        saving: false, activity: history.bars(microphone: true),
                                        activityTime: history.bucketStart, tint: .accentColor)
                                    // Off shows the echo hint; On shows the automatic-change notice.
                                    RecordingVoiceProcessingControl(
                                        status: RecordingMicrophoneStatus(
                                            voiceProcessing: previewVoiceProcessing, canSwitch: true,
                                            echoDetected: !previewVoiceProcessing,
                                            notices: previewVoiceProcessing
                                                ? ["Echo detected · Voice Processing turned on"] : [])
                                    ) { previewVoiceProcessing = $0 }
                                }
                                RecordingSourceMeter(
                                    title: "System Audio", symbol: "speaker.wave.2.fill",
                                    source: Self.recordingLevel(
                                        at: now, offset: 3, reconnects: true),
                                    saving: false, activity: history.bars(microphone: false),
                                    activityTime: history.bucketStart, tint: .teal)
                            }
                        }.padding(18).frame(maxWidth: 500)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            content()
        }
        .onChange(of: appearance) { _, selection in
            guard UIPreview.enabled else { return }
            // Use one AppKit appearance source for native controls and SwiftUI.
            // Removing preferredColorScheme left stale dark foregrounds until
            // window activation; nil here restores live system inheritance.
            NSApp.appearance =
                selection == 1
                ? NSAppearance(named: .aqua)
                : selection == 2 ? NSAppearance(named: .darkAqua) : nil
        }
    }
}
