import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingLanguageTests {
    @Test func explicitLanguageRequiredBeforeEitherProviderUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        for language in ["auto", " AUTO ", "", " "] {
            let id = await store.createMeeting(title: "Choose language", language: language)
            for kind in [ServiceProviderKind.runpod, .gdayWebsite] {
                do {
                    try await store.transcribeWithProvider(id: id, provider: ServiceProvider(kind: kind))
                    Issue.record("A language must be chosen before contacting a provider")
                }
                catch {
                    #expect(error.localizedDescription == "Choose a language for this meeting.")
                }
                #expect(store.meetings.first { $0.id == id }?.transcriptionAttempt == nil)
            }
        }
    }

    @Test func missingLanguageDefaultsToEnglish() throws {
        #expect(try JSONDecoder().decode(Meeting.self, from: Data("{}".utf8)).language == "en")
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).defaultLanguage == "en")
    }

    @Test func defaultAppliesOnlyToNewMeetingsAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.defaultLanguage = "zh-cn"
        let chinese = await store.createMeeting(title: "Chinese meeting")
        store.settings.defaultLanguage = "ja"
        let japanese = await store.createMeeting(title: "Japanese meeting")
        #expect(store.meetings.first { $0.id == chinese }?.language == "zh-cn")
        #expect(store.meetings.first { $0.id == japanese }?.language == "ja")
        #expect(store.saveSettings())
        let restored = MeetingStore(dataDirectory: root)
        #expect(restored.settings.defaultLanguage == "ja")
        #expect(await restored.ensureMeetingLoaded(id: chinese))
        #expect(restored.meeting(id: chinese)?.language == "zh-cn")
    }

    @Test func attemptSnapshotsMeetingLanguageAndRequestKeepsRegionalCode() throws {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = "https://example.com/v2/transcription"
        provider.apiKey = "test-key"
        provider.enabledCapabilities = [.transcription]
        for code in ["zh-cn", "zh-tw"] {
            var meeting = Meeting(title: "Regional language", language: code)
            let attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
            meeting.language = "ja"
            let restored = try JSONDecoder().decode(
                ProviderTranscriptionAttempt.self, from: JSONEncoder().encode(attempt))
            #expect(restored.language == code)
            #expect(meeting.language == "ja")
            let request = try RunPodProvider(provider: provider).submissionRequest(
                tracks: [
                    .init(url: URL(string: "https://files.example/audio.opus")!, trackName: "mic", sourceType: "mic")
                ],
                language: restored.language, diarize: false)
            let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let input = try #require(json["input"] as? [String: Any])
            #expect(input["language"] as? String == code)
        }
        let encoded = String(decoding: try JSONEncoder().encode(provider), as: UTF8.self)
        #expect(!encoded.contains("language"))
    }

    @Test func rustImportPreservesMeetingLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("rust/recordings/meeting")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data(#"{"name":"Imported","language":"zh-tw"}"#.utf8).write(
            to: recording.appendingPathComponent("metadata.json"))
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("swift"))
        store.settings.defaultLanguage = "ja"
        #expect(try await store.importLegacyLibrary(url: root.appendingPathComponent("rust")) == 1)
        #expect(store.meetings.first?.language == "zh-tw")
    }
}
