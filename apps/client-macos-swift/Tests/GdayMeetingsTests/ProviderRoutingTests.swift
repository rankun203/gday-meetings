import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ProviderRoutingTests {
    private func store() throws -> MeetingStore {
        MeetingStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func noProviderDoesNotStartTranscription() async throws {
        let store = try store()
        let id = store.createMeeting(title: "Offline recording")
        await store.transcribe(id: id)
        #expect(store.errorMessage == nil)
        #expect(store.managedTasks.last?.errorMessage == "Choose a transcription provider in Settings → Defaults.")
        #expect(store.meetings.first?.transcriptionAttempt == nil)
        #expect(store.backgroundJobs.isEmpty)
    }

    @Test func missingSummaryProviderPointsToDefaults() throws {
        let store = try store()
        #expect {
            _ = try store.summaryProvider()
        } throws: { error in
            error.localizedDescription == "Choose and enable a summary provider in Settings → Defaults."
        }
    }

    @Test func runpodRequiresExplicitEnabledUploadProvider() throws {
        let store = try store()
        var runpod = ServiceProvider(kind: .runpod)
        runpod.enabledCapabilities = [.transcription]
        var upload = ServiceProvider(kind: .filedrop)
        upload.enabledCapabilities = [.fileTransfer]
        store.settings.serviceProviders = [runpod, upload]
        store.settings.transcriptionProviderID = runpod.id
        #expect(throws: (any Error).self) { try store.transcriptionProvider(for: Meeting()) }
        runpod.uploadProviderID = upload.id
        store.settings.serviceProviders = [runpod, upload]
        #expect(try store.transcriptionProvider(for: Meeting()).id == runpod.id)
        upload.isEnabled = false
        store.settings.serviceProviders = [runpod, upload]
        #expect(throws: (any Error).self) { try store.transcriptionProvider(for: Meeting()) }
    }

    @Test func pendingJobRetainsProviderAndEndpoint() throws {
        let store = try store()
        var old = ServiceProvider(kind: .runpod)
        old.endpoint = "https://old.example/v2/endpoint"
        old.enabledCapabilities = [.transcription]
        var newer = ServiceProvider(kind: .runpod)
        newer.enabledCapabilities = [.transcription]
        store.settings.serviceProviders = [old, newer]
        store.settings.transcriptionProviderID = newer.id
        var meeting = Meeting()
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(
            providerID: old.id, endpoint: old.endpoint, kind: old.kind, title: meeting.title, taskID: "saved-job")
        #expect(try store.transcriptionProvider(for: meeting).id == old.id)
        old.endpoint = "https://changed.example/v2/endpoint"
        store.settings.serviceProviders = [old, newer]
        #expect(throws: (any Error).self) { try store.transcriptionProvider(for: meeting) }
    }

    @Test func editedTranscriptRetainsCompletedResultForExplicitReplacement() throws {
        let store = try store()
        let id = store.createMeeting(title: "Edited transcript")
        let meeting = try #require(store.meetings.first { $0.id == id })
        let generated = [TranscriptSegment(start: 1.5, end: 3.0, speaker: "Speaker A", text: "Generated text")]
        let attempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://example.test", kind: .runpod, title: meeting.title,
            originalTranscript: [], result: generated)
        try store.saveTranscriptionAttempt(attempt, meetingID: meeting.id)
        var edited = try #require(store.meetings.first)
        edited.transcript = [TranscriptSegment(text: "An edit made during processing")]
        store.updateMeeting(edited)
        #expect(throws: (any Error).self) {
            try store.saveTranscriptionResult(generated, attempt: attempt, meetingID: meeting.id)
        }
        #expect(store.meetings.first?.transcript == edited.transcript)
        #expect(store.meetings.first?.transcriptionAttempt?.result == generated)
        store.applySavedTranscriptionResult(meetingID: meeting.id)
        let applied = try #require(store.meetings.first)
        #expect(applied.transcript.count == generated.count)
        let segment = try #require(applied.transcript.first)
        #expect(segment.id == generated[0].id)
        #expect(segment.text == generated[0].text)
        #expect(segment.start == generated[0].start)
        #expect(segment.end == generated[0].end)
        #expect(segment.speaker == generated[0].speaker)
        let identity = try #require(applied.speakers.first { $0.id == segment.speakerID })
        #expect(identity.label == generated[0].speaker)
        #expect(identity.personID == nil)
        #expect(applied.transcriptionAttempt == nil)
    }

    @Test func completedProviderResultSelectsNewSourceAndPreservesLiveVersion() throws {
        let store = try store()
        let id = store.createMeeting(title: "Live then provider")
        var meeting = try #require(store.meeting(id: id))
        let liveSource = TranscriptSource(id: UUID(), providerName: "This Mac", generatedAt: Date())
        meeting.transcript = [.init(text: "Live words")]
        meeting.transcriptSource = liveSource
        meeting.liveTranscriptAdopted = true
        store.updateMeeting(meeting)
        let otherID = store.createMeeting(title: "Another meeting")
        let other = try #require(store.meeting(id: otherID))
        let result = [TranscriptSegment(text: "Provider words")]
        let attempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://example.test", kind: .runpod, title: meeting.title,
            originalTranscript: meeting.transcript, result: result)
        try store.saveTranscriptionResult(result, attempt: attempt, meetingID: id)
        let applied = try #require(store.meeting(id: id))
        #expect(applied.transcript.map(\.text) == ["Provider words"])
        #expect(applied.transcriptSource?.id != liveSource.id)
        #expect(applied.transcriptSource?.providerName == "RunPod")
        let history = try TranscriptRevisions.read(at: store.directory(for: id)).revisions
        #expect(history.contains { $0.id == liveSource.id && $0.segments == meeting.transcript })
        #expect(store.meeting(id: otherID)?.transcript == other.transcript)
    }
}
