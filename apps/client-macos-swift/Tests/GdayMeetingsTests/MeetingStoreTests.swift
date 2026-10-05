import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func librarySurvivesRestartAndRelationshipDeletion() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MeetingStore(dataDirectory: url)
        let id = await store.createMeeting(title: "Design review")
        let person = await store.addPerson(name: "Alex")
        let tag = await store.addTag(name: "Project")
        var meeting = try #require(store.meetings.first)
        meeting.notes = "Decision preserved"
        meeting.personIDs = [person]
        meeting.tagIDs = [tag]
        meeting.transcript = [TranscriptSegment(start: 1, end: 3, speaker: "Alex", text: "Ship it")]
        meeting.todos = [MeetingTodo(title: "Send update")]
        await store.updateMeeting(meeting)
        let restored = MeetingStore(dataDirectory: url)
        #expect(await restored.ensureMeetingLoaded(id: id))
        #expect(restored.meeting(id: id)?.id == id)
        #expect(restored.meeting(id: id)?.notes == "Decision preserved")
        #expect(restored.meeting(id: id)?.transcript == meeting.transcript)
        await restored.deletePerson(id: person)
        await restored.deleteTag(id: tag)
        let final = MeetingStore(dataDirectory: url)
        #expect(await final.ensureMeetingLoaded(id: id))
        #expect(final.meeting(id: id)?.personIDs.isEmpty == true)
        #expect(final.meeting(id: id)?.tagIDs.isEmpty == true)
    }
    @Test func corruptLibraryNeverOverwritten() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("settings.json")
        let content = Data("{broken".utf8)
        try content.write(to: file)
        let store = MeetingStore(dataDirectory: url)
        #expect(store.errorMessage != nil)
        await store.createMeeting(title: "Cannot save")
        #expect(try Data(contentsOf: file) == content)
    }
    @Test func defaultsAndCredentialsDoNotPersist() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.captureMicrophone)
        #expect(settings.serviceProviders.isEmpty)
        var secret = settings
        var provider = ServiceProvider(kind: .runpod)
        provider.apiKey = "private-audio"
        secret.serviceProviders = [provider]
        let encoded = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        #expect(!encoded.contains("private-"))
        #expect(!encoded.contains("APIKey"))
    }
    @Test func archiveImportDropsUntrustedAudioPathsAndIDs() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MeetingStore(dataDirectory: url)
        let original = Meeting(title: "Imported", audioFiles: ["../../secret", "/tmp/private"])
        let file = url.appendingPathComponent("import.json")
        try JSONEncoder().encode(original).write(to: file)
        try await store.importArchive(url: file)
        #expect(store.meetings.first?.id != original.id)
        #expect(store.meetings.first?.audioFiles.isEmpty == true)
    }
    @Test func legacyImportCopiesWithoutChangingSource() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = url.appendingPathComponent("legacy/session")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let metadata = Data("{\"name\":\"Legacy meeting\",\"notes\":\"Keep me\",\"duration_secs\":25}".utf8)
        try metadata.write(to: source.appendingPathComponent("metadata.json"))
        let audio = Data([1, 2, 3])
        try audio.write(to: source.appendingPathComponent("mic.wav"))
        let store = MeetingStore(dataDirectory: url.appendingPathComponent("native"))
        #expect(try await store.importLegacyLibrary(url: source.deletingLastPathComponent()) == 1)
        #expect(store.meetings.first?.notes == "Keep me")
        #expect(try Data(contentsOf: source.appendingPathComponent("metadata.json")) == metadata)
        let importedMeeting = try #require(store.meetings.first)
        let imported = try #require(store.audioURL(for: importedMeeting))
        #expect(try Data(contentsOf: imported) == audio)
    }
    @Test func progressTextClearsWhenWorkEnds() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MeetingStore(dataDirectory: url)
        #expect(store.beginJob(.summary, .library, progress: "Writing summary…"))
        store.endJob(.summary, .library)
        #expect(store.statusMessage.isEmpty)
    }
    @Test func missingRecordedSourceFailsFinalizationWithoutChangingMetadata() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MeetingStore(dataDirectory: url)
        let id = await store.createMeeting(title: "Synthetic recording")
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        await #expect(throws: (any Error).self) {
            try await store.finalizeRecordingAudio(id: id, format: .m4a)
        }
        #expect(store.meeting(id: id)?.audioFiles == ["microphone.wav"])
        #expect(
            !FileManager.default.fileExists(
                atPath: store.directory(for: id).appendingPathComponent("microphone.m4a").path))
        #expect(store.backgroundJobs.isEmpty && !store.isFinalizingRecording)
    }
}

@MainActor struct MeetingIntegrityTests {
    @Test func failedWriteRollsBackMemoryAndPreservesLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.createMeeting(title: "Saved")
        let id = try #require(store.meetings.first?.id)
        let path = store.directory(for: id).appendingPathComponent("metadata.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        var changed = try #require(store.meeting(id: id))
        changed.title = "Cannot save"
        #expect(await store.updateMeeting(changed) == false)
        #expect(store.meetings.count == 1)
        #expect(store.meetings.first?.title == "Saved")
        #expect(store.errorMessage != nil)
    }
    @Test func actionableSummaryCheckboxesOnly() {
        let todos = MeetingStore.actionItems(
            from: "# Summary\n- General discussion\n- [ ] Send report\n- [x] Confirm scope\n- [ ] send report\n- [ ] ")
        #expect(todos.count == 2)
        #expect(todos[0].title == "Send report")
        #expect(todos[1].isCompleted)
    }
    @Test func contextualChatPersistsIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = await store.addPerson(name: "Taylor")
        let key = MeetingStore.contextChatKey(personID: person)
        await store.saveContextChat(key: key, messages: [ChatMessage(content: "What did we decide?")])
        #expect(MeetingStore(dataDirectory: root).contextualChats[key]?.first?.content == "What did we decide?")
    }
    @Test func archiveRemovesPrivateTaskCapability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Private task")
        var meeting = try #require(store.meetings.first)
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://example.com", kind: .gdayWebsite, title: "Private")
        await store.updateMeeting(meeting)
        let file = root.appendingPathComponent("export.json")
        try await store.exportMeeting(id: id, to: file)
        let output = try String(contentsOf: file, encoding: .utf8)
        #expect(!output.contains("secret"))
        try await store.importArchive(url: file)
        #expect(store.meetings.first?.transcriptionAttempt == nil)
    }
}

@Test func errorAlertUsesFirstSentenceAsTitle() {
    let parts = LibraryView.alertParts("Couldn’t finish the recording. Audio is kept. Core Audio -50.")
    #expect(parts.title == "Couldn’t finish the recording.")
    #expect(parts.message == "Audio is kept. Core Audio -50.")
    #expect(LibraryView.alertParts("No microphone input is available.").message.isEmpty)
}
