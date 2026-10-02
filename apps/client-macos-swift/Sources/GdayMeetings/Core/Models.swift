import Foundation

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double = 0
    var end: Double = 0
    var speaker = "Speaker"
    var text = ""
    var speakerID: UUID?
    enum CodingKeys: String, CodingKey { case id, start, end, speaker, text, speakerID }

}
struct MeetingTodo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var isCompleted = false
    enum CodingKeys: String, CodingKey { case id, title, isCompleted }

}
struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role = "user"
    var content = ""
    var createdAt = Date()
    enum CodingKeys: String, CodingKey { case id, role, content, createdAt }

}
struct Meeting: Codable, Identifiable, Equatable {
    var id = MeetingIdentity.newID()
    var title = "Untitled Meeting"
    var language = "en"
    var createdAt = Date()
    var duration: TimeInterval = 0
    var notes = ""
    var summary = ""
    var transcript: [TranscriptSegment] = []
    var transcriptSource: TranscriptSource?
    var liveTranscriptAdopted = false
    var speakers: [MeetingSpeaker] = []
    var personIDs: [UUID] = []
    var tagIDs: [UUID] = []
    var audioFiles: [String] = []
    var chat: [ChatMessage] = []
    var todos: [MeetingTodo] = []
    var recordingProfile: RecordingProfile?
    var transcriptionAttempt: ProviderTranscriptionAttempt?
    var completedTaskIDs: [String: UUID] = [:]
    enum CodingKeys: String, CodingKey {
        case id, title, language, createdAt, duration, notes, summary, transcript, personIDs, tagIDs, audioFiles, chat,
            todos,
            recordingProfile, transcriptionAttempt, speakers, liveTranscriptAdopted, completedTaskIDs, transcriptSource
    }

}
struct Person: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var email = ""
    var notes = ""
    var voiceSamples: [PersonVoiceSample] = []
    var tagIDs: [UUID] = []
    enum CodingKeys: String, CodingKey { case id, name, email, notes, voiceSamples, tagIDs }

}
struct MeetingTag: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var color = "blue"
    var isExcluded = false
    enum CodingKeys: String, CodingKey { case id, name, color, isExcluded }

}
enum RecordingFormat: String, Codable, CaseIterable {
    case opus, m4a, wav
}

/// A microphone chosen in New Recording. The UID identifies the device when it
/// reconnects; the name labels it while it is disconnected.
struct MicrophoneDeviceChoice: Codable, Equatable {
    var uid: String
    var name: String
}

struct AppSettings: Codable, Equatable {
    var serviceProviders: [ServiceProvider] = []
    var transcriptionProviderID: UUID?
    var summaryProviderID: UUID?
    var liveDiarizationProviderID: UUID?
    var diarizationProviderID: UUID?
    var speakerRecognitionProviderID: UUID?
    var showLiveSpeakerLabels = false
    var labelRecordedSpeakers = false
    var explicitlyDisabledFeatures: Set<String> = []
    var initializedProviderCapabilities: Set<ProviderCapability> = []
    var recognizeSpeakers = false
    var recognizeLiveSpeakers = false
    var liveSpeakerRecognitionEnabled: Bool {
        get { showLiveSpeakerLabels || recognizeLiveSpeakers }
        set {
            showLiveSpeakerLabels = newValue
            recognizeLiveSpeakers = newValue
        }
    }
    var defaultLanguage = "en"
    var autoSummarize = false
    var autoExtractTodos = true
    var autoTranscribe = false
    var autoTranscribeEvenWithLiveTranscript = false
    var liveTranscriptionProviderID: UUID? = ThisMacProvider.id
    var thisMacCapabilities: Set<ProviderCapability> = ThisMacProvider.capabilities
    var liveTranscriptionEnabled: Bool {
        showLiveTranscript && liveTranscriptionProviderID == ThisMacProvider.id
            && thisMacCapabilities.contains(.liveTranscription)
    }
    var showLiveTranscript = true
    var captureSystemAudio = true
    var captureMicrophone = true
    var recordingFormat: RecordingFormat = .opus
    /// On: voice processing follows the output route and turns on when echo is
    /// detected. Off: recordings start unprocessed and nothing turns it on.
    var automaticVoiceProcessing = true
    /// `nil` records from the macOS default input.
    var microphoneDevice: MicrophoneDeviceChoice?
    enum CodingKeys: String, CodingKey {
        case serviceProviders, transcriptionProviderID, summaryProviderID,
            liveDiarizationProviderID, diarizationProviderID, speakerRecognitionProviderID,
            showLiveSpeakerLabels, recognizeSpeakers, recognizeLiveSpeakers, labelRecordedSpeakers,
            initializedProviderCapabilities, explicitlyDisabledFeatures,
            defaultLanguage, autoTranscribe, autoSummarize, autoExtractTodos,
            autoTranscribeEvenWithLiveTranscript, showLiveTranscript, liveTranscriptionProviderID, thisMacCapabilities,
            captureSystemAudio,
            captureMicrophone, recordingFormat, automaticVoiceProcessing, microphoneDevice
    }

}
/// In-memory baseline for dirty checking and rollback; never serialized as a library.
struct LibrarySnapshot {
    var contextualChats: [String: [ChatMessage]] = [:]
    var meetings: [Meeting] = []
    var people: [Person] = []
    var tags: [MeetingTag] = []
}
enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension TranscriptSegment {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try values.decodeIfPresent(Double.self, forKey: .end) ?? 0
        speaker = try values.decodeIfPresent(String.self, forKey: .speaker) ?? "Speaker"
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        speakerID = try values.decodeIfPresent(UUID.self, forKey: .speakerID)
    }
}

extension MeetingTodo {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
    }
}

extension ChatMessage {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? "user"
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

extension Meeting {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        completedTaskIDs = try values.decodeIfPresent([String: UUID].self, forKey: .completedTaskIDs) ?? [:]
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Meeting"
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        transcript = try values.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        transcriptSource = try values.decodeIfPresent(TranscriptSource.self, forKey: .transcriptSource)
        liveTranscriptAdopted = try values.decodeIfPresent(Bool.self, forKey: .liveTranscriptAdopted) ?? false
        speakers = try values.decodeIfPresent([MeetingSpeaker].self, forKey: .speakers) ?? []
        personIDs = try values.decodeIfPresent([UUID].self, forKey: .personIDs) ?? []
        tagIDs = try values.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        audioFiles = try values.decodeIfPresent([String].self, forKey: .audioFiles) ?? []
        chat = try values.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
        todos = try values.decodeIfPresent([MeetingTodo].self, forKey: .todos) ?? []
        recordingProfile = try values.decodeIfPresent(RecordingProfile.self, forKey: .recordingProfile)
        transcriptionAttempt = try values.decodeIfPresent(
            ProviderTranscriptionAttempt.self, forKey: .transcriptionAttempt)
    }
}

extension Person {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        voiceSamples = try values.decodeIfPresent([PersonVoiceSample].self, forKey: .voiceSamples) ?? []
        tagIDs = try values.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

extension MeetingTag {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        isExcluded = try values.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
    }
}

extension AppSettings {
    /// Evaluate after live recognition finishes for the recording being saved.
    /// Empty sessions and provisional text do not count as finalized live text.
    func shouldAutomaticallyTranscribe(hasUsableFinalizedLiveTranscript: Bool) -> Bool {
        autoTranscribe && (autoTranscribeEvenWithLiveTranscript || !hasUsableFinalizedLiveTranscript)
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceProviders = try values.decodeIfPresent([ServiceProvider].self, forKey: .serviceProviders) ?? []
        transcriptionProviderID = try values.decodeIfPresent(UUID.self, forKey: .transcriptionProviderID)
        summaryProviderID = try values.decodeIfPresent(UUID.self, forKey: .summaryProviderID)
        liveDiarizationProviderID = try values.decodeIfPresent(UUID.self, forKey: .liveDiarizationProviderID)
        diarizationProviderID = try values.decodeIfPresent(UUID.self, forKey: .diarizationProviderID)
        speakerRecognitionProviderID = try values.decodeIfPresent(UUID.self, forKey: .speakerRecognitionProviderID)
        showLiveSpeakerLabels = try values.decodeIfPresent(Bool.self, forKey: .showLiveSpeakerLabels) ?? false
        recognizeSpeakers = try values.decodeIfPresent(Bool.self, forKey: .recognizeSpeakers) ?? false
        recognizeLiveSpeakers = try values.decodeIfPresent(Bool.self, forKey: .recognizeLiveSpeakers) ?? false
        labelRecordedSpeakers =
            try values.decodeIfPresent(Bool.self, forKey: .labelRecordedSpeakers) ?? recognizeSpeakers
        explicitlyDisabledFeatures =
            try values.decodeIfPresent(Set<String>.self, forKey: .explicitlyDisabledFeatures) ?? []
        initializedProviderCapabilities =
            try values.decodeIfPresent(Set<ProviderCapability>.self, forKey: .initializedProviderCapabilities) ?? []
        defaultLanguage = try values.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? "en"
        autoSummarize = try values.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? false
        autoExtractTodos = try values.decodeIfPresent(Bool.self, forKey: .autoExtractTodos) ?? true
        autoTranscribe = try values.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? false
        autoTranscribeEvenWithLiveTranscript =
            try values.decodeIfPresent(Bool.self, forKey: .autoTranscribeEvenWithLiveTranscript) ?? false
        liveTranscriptionProviderID = try values.decodeIfPresent(UUID.self, forKey: .liveTranscriptionProviderID)
        thisMacCapabilities =
            try values.decodeIfPresent(Set<ProviderCapability>.self, forKey: .thisMacCapabilities)
            ?? ThisMacProvider.capabilities
        showLiveTranscript = try values.decodeIfPresent(Bool.self, forKey: .showLiveTranscript) ?? true
        captureSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        captureMicrophone = try values.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? true
        recordingFormat = try values.decodeIfPresent(RecordingFormat.self, forKey: .recordingFormat) ?? .opus
        automaticVoiceProcessing = try values.decodeIfPresent(Bool.self, forKey: .automaticVoiceProcessing) ?? true
        microphoneDevice = try? values.decodeIfPresent(MicrophoneDeviceChoice.self, forKey: .microphoneDevice)
        if !values.contains(.explicitlyDisabledFeatures) {
            let legacyFeatures: [(CodingKeys, WritableKeyPath<AppSettings, Bool>)] = [
                (.showLiveTranscript, \.showLiveTranscript),
                (.showLiveSpeakerLabels, \.showLiveSpeakerLabels),
                (.recognizeLiveSpeakers, \.recognizeLiveSpeakers),
                (.recognizeSpeakers, \.recognizeSpeakers),
                (.autoTranscribe, \.autoTranscribe),
                (.autoSummarize, \.autoSummarize),
                (.autoExtractTodos, \.autoExtractTodos),
            ]
            for (key, path) in legacyFeatures where values.contains(key) && !self[keyPath: path] {
                recordExplicitFeatureChoice(path, enabled: false)
            }
            if values.contains(.recognizeSpeakers), !labelRecordedSpeakers {
                recordExplicitFeatureChoice(\.labelRecordedSpeakers, enabled: false)
            }
        }
        if !values.contains(.initializedProviderCapabilities) {
            for capability in ProviderCapability.allCases where selectedProvider(for: capability) != nil {
                initializedProviderCapabilities.insert(capability)
            }
        }

    }
}

// Export encoders may omit notes when publishing a separate Markdown sidecar.
extension CodingUserInfoKey {
    static let notesInSidecars = CodingUserInfoKey(rawValue: "notesInSidecars")!
}
extension Meeting {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(completedTaskIDs, forKey: .completedTaskIDs)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(language, forKey: .language)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(duration, forKey: .duration)
        if encoder.userInfo[.notesInSidecars] as? Bool != true { try values.encode(notes, forKey: .notes) }
        try values.encode(summary, forKey: .summary)
        try values.encode(transcript, forKey: .transcript)
        try values.encodeIfPresent(transcriptSource, forKey: .transcriptSource)
        try values.encode(liveTranscriptAdopted, forKey: .liveTranscriptAdopted)
        try values.encode(speakers, forKey: .speakers)
        try values.encode(personIDs, forKey: .personIDs)
        try values.encode(tagIDs, forKey: .tagIDs)
        try values.encode(audioFiles, forKey: .audioFiles)
        try values.encode(chat, forKey: .chat)
        try values.encode(todos, forKey: .todos)
        try values.encodeIfPresent(recordingProfile, forKey: .recordingProfile)
        try values.encodeIfPresent(transcriptionAttempt, forKey: .transcriptionAttempt)
    }
}
