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
    var id = UUID()
    var title = "Untitled Meeting"
    var language = "en"
    var createdAt = Date()
    var duration: TimeInterval = 0
    var notes = ""
    var summary = ""
    var transcript: [TranscriptSegment] = []
    var speakers: [MeetingSpeaker] = []
    var personIDs: [UUID] = []
    var tagIDs: [UUID] = []
    var audioFiles: [String] = []
    var chat: [ChatMessage] = []
    var todos: [MeetingTodo] = []
    var recordingProfile: RecordingProfile?
    var transcriptionAttempt: ProviderTranscriptionAttempt?
    enum CodingKeys: String, CodingKey {
        case id, title, language, createdAt, duration, notes, summary, transcript, personIDs, tagIDs, audioFiles, chat,
            todos,
            recordingProfile, transcriptionAttempt, speakers
    }

}
struct Person: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var email = ""
    var notes = ""
    var voiceSamples: [PersonVoiceSample] = []
    enum CodingKeys: String, CodingKey { case id, name, email, notes, voiceSamples }

}
struct MeetingTag: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var color = "blue"
    enum CodingKeys: String, CodingKey { case id, name, color }

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
    var defaultLanguage = "en"
    var autoTranscribe = false
    var showLiveTranscript = true
    var captureSystemAudio = true
    var captureMicrophone = true
    var recordingFormat: RecordingFormat = .opus
    /// On: voice processing follows the output route and turns on when echo is
    /// detected. Off: recordings start unprocessed and nothing turns it on.
    var automaticVoiceProcessing = true
    /// `nil` records from the macOS default input.
    var microphoneDevice: MicrophoneDeviceChoice?
    var summarizationPrompt =
        "Summarize this meeting with decisions, key points, and action items. Do not invent information."
    enum CodingKeys: String, CodingKey {
        case serviceProviders, transcriptionProviderID, summaryProviderID, defaultLanguage, autoTranscribe,
            showLiveTranscript,
            captureSystemAudio,
            captureMicrophone, recordingFormat, summarizationPrompt, automaticVoiceProcessing, microphoneDevice
    }

}
/// `library.json` format contract:
/// - Increase `currentVersion` for every layout change, including data moved
///   out of `library.json`, and add the step from the previous version to
///   `migrations`.
/// - This build opens versions up to `currentVersion`, migrating older ones
///   after keeping a backup. It never opens or rewrites a newer version, and it
///   always saves `currentVersion`, so a save cannot lower the version.
struct MeetingLibrary: Codable {
    static let currentVersion = 3
    typealias Migration = (inout MeetingLibrary) throws -> Void
    /// Version 2 retains speaker identity and confirmed voice samples. New fields
    /// decode empty in version 1; no existing speaker name implies a person.
    static let migrations: [Int: Migration] = [
        1: { library in
            for index in library.meetings.indices { library.meetings[index].restoreSpeakerIdentities() }
        },
        // Sidecar file work runs in LibraryFormat before the version advances.
        2: { _ in },
    ]

    var contextualChats: [String: [ChatMessage]] = [:]
    var version = MeetingLibrary.currentVersion
    var meetings: [Meeting] = []
    var people: [Person] = []
    var tags: [MeetingTag] = []
    enum CodingKeys: String, CodingKey { case version, meetings, people, tags, contextualChats }

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
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Meeting"
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        transcript = try values.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
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
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceProviders = try values.decodeIfPresent([ServiceProvider].self, forKey: .serviceProviders) ?? []
        transcriptionProviderID = try values.decodeIfPresent(UUID.self, forKey: .transcriptionProviderID)
        summaryProviderID = try values.decodeIfPresent(UUID.self, forKey: .summaryProviderID)
        defaultLanguage = try values.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? "en"
        autoTranscribe = try values.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? false
        showLiveTranscript = try values.decodeIfPresent(Bool.self, forKey: .showLiveTranscript) ?? true
        captureSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        captureMicrophone = try values.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? true
        recordingFormat = try values.decodeIfPresent(RecordingFormat.self, forKey: .recordingFormat) ?? .opus
        // A new key: the legacy `microphoneVoiceProcessing` preference stays ignored.
        automaticVoiceProcessing = try values.decodeIfPresent(Bool.self, forKey: .automaticVoiceProcessing) ?? true
        microphoneDevice = try? values.decodeIfPresent(MicrophoneDeviceChoice.self, forKey: .microphoneDevice)
        summarizationPrompt =
            try values.decodeIfPresent(String.self, forKey: .summarizationPrompt)
            ?? "Summarize this meeting with decisions, key points, and action items. Do not invent information."
    }
}

extension MeetingLibrary {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contextualChats = try values.decodeIfPresent([String: [ChatMessage]].self, forKey: .contextualChats) ?? [:]
        // Files written before the key existed use the version 1 layout.
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        meetings = try values.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
        people = try values.decodeIfPresent([Person].self, forKey: .people) ?? []
        tags = try values.decodeIfPresent([MeetingTag].self, forKey: .tags) ?? []
    }
}

// Only the library index omits notes; standalone meeting JSON retains Markdown.
extension CodingUserInfoKey {
    static let notesInSidecars = CodingUserInfoKey(rawValue: "notesInSidecars")!
}
extension Meeting {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(language, forKey: .language)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(duration, forKey: .duration)
        if encoder.userInfo[.notesInSidecars] as? Bool != true { try values.encode(notes, forKey: .notes) }
        try values.encode(summary, forKey: .summary)
        try values.encode(transcript, forKey: .transcript)
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
