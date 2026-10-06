import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordedTranscriptionTests {
    private func store() -> MeetingStore {
        MeetingStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func thisMacNeedsNoRemoteProviderAndRespectsEnablement() throws {
        let store = store()
        #expect(store.eligibleTranscriptionProviders.map(\.id) == [ThisMacProvider.id])
        #expect(try store.transcriptionProvider(for: Meeting(), providerID: ThisMacProvider.id).kind == .appleSpeech)
        store.settings.thisMacCapabilities.remove(.transcription)
        #expect(store.eligibleTranscriptionProviders.isEmpty)
        #expect(throws: (any Error).self) {
            try store.transcriptionProvider(for: Meeting(), providerID: ThisMacProvider.id)
        }
    }

    @Test func localAttemptRemainsLocalWhenDefaultChanges() throws {
        let store = store()
        let local = ThisMacProvider.transcriptionProvider(settings: store.settings)
        var meeting = Meeting()
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(provider: local, meeting: meeting)
        let remote = ServiceProvider(kind: .gdayWebsite)
        store.settings.serviceProviders = [remote]
        store.settings.transcriptionProviderID = remote.id
        #expect(try store.transcriptionProvider(for: meeting).id == ThisMacProvider.id)
        #expect(throws: (any Error).self) { try store.transcriptionProvider(for: meeting, providerID: remote.id) }
        let decoded = try JSONDecoder().decode(
            ProviderTranscriptionAttempt.self,
            from: JSONEncoder().encode(meeting.transcriptionAttempt!))
        #expect(decoded.kind == .appleSpeech)
    }

    @Test func migrationAddsRecordedCapabilityOnce() throws {
        let old = Data(#"{"thisMacCapabilities":[]}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.thisMacCapabilities == [.transcription])
        settings.thisMacCapabilities.remove(.transcription)
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: saved).thisMacCapabilities.isEmpty)
    }

    @Test func savedLocalResultPreservesEditsAndHistory() async throws {
        let store = store()
        let id = await store.createMeeting(title: "Sample recording")
        var meeting = try #require(store.meeting(id: id))
        meeting.transcript = [.init(start: 0, end: 1, text: "Original text")]
        #expect(await store.updateMeeting(meeting))
        let local = ThisMacProvider.transcriptionProvider(settings: store.settings)
        var attempt = ProviderTranscriptionAttempt(provider: local, meeting: meeting)
        let generated = [TranscriptSegment(start: 0, end: 1, text: "Generated text")]
        attempt.result = generated
        try await store.saveTranscriptionAttempt(attempt, meetingID: id)
        meeting = try #require(store.meeting(id: id))
        meeting.transcript[0].text = "Edited text"
        #expect(await store.updateMeeting(meeting))
        await #expect(throws: (any Error).self) {
            try await store.saveTranscriptionResult(generated, attempt: attempt, meetingID: id)
        }
        #expect(store.meeting(id: id)?.transcript.first?.text == "Edited text")
        #expect(store.meeting(id: id)?.transcriptionAttempt?.result == generated)
        await store.applySavedTranscriptionResult(meetingID: id)
        #expect(store.meeting(id: id)?.transcript.map(\.text) == generated.map(\.text))
        let history = try TranscriptRevisions.read(at: store.directory(for: id)).revisions
        #expect(history.contains { $0.segments.first?.text == "Edited text" })
        #expect(store.meeting(id: id)?.transcriptSource?.providerName == "This Mac")
        #expect(store.meeting(id: id)?.transcriptionAttempt == nil)
    }
}

struct AppleRecordedTranscriptionSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_APPLE_RECORDED_TEST"] == "1"))
    func generatedSpeechAndOpusTracks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = directory.appendingPathComponent("microphone.aiff")
        let system = directory.appendingPathComponent("system.opus")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Karen", "-o", microphone.path,
            "This is a sample recording. Please review the report on Friday.",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try await RecordingEncoder.encode(source: microphone, destination: system, format: .opus)
        let result = try await AppleRecordedTranscription.transcribe(
            files: [microphone, system], meetingID: UUID(), language: "en", status: { _ in })
        #expect(result.complete)
        #expect(result.segments.contains { $0.source == .microphone && !$0.text.isEmpty })
        #expect(result.segments.contains { $0.source == .system && !$0.text.isEmpty })
        #expect(result.segments.allSatisfy { $0.start.isFinite && $0.end > $0.start && $0.sourcePlaceholder == true })
        #expect(result.speakers.allSatisfy { $0.providerName == "This Mac" && $0.sourcePlaceholder != nil })
    }
}
