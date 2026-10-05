import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LiveTranscriptAdoptionTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func draft(_ id: UUID) -> LiveTranscriptDraft {
        var value = LiveTranscriptDraft(meetingID: id, locale: "en-US")
        value.accept(.init(session: UUID(), source: .microphone, start: 1, end: 2, text: "First"))
        value.accept(.init(session: UUID(), source: .system, start: 3, end: 4, text: "Second"))
        return value
    }
    @Test func liveAndUnlabeledBatchUseTimedTextWithoutPeople() {
        let live = draft(UUID())
        let batch = SpeakerRecognition.result(
            [.init(start: 1, end: 2, text: "First", speaker: nil, track: "mic", embedding: nil)],
            attempt: .init(provider: .init(kind: .runpod), meeting: Meeting()), people: [])
        #expect(live.segments.map(\.speaker) == ["mic", "sys"])
        #expect(live.speakers.allSatisfy { $0.personID == nil && $0.embedding == nil })
        #expect(batch.segments.first?.speaker == "")
        #expect(batch.segments.first?.speakerID == nil)
        #expect(batch.speakers.isEmpty)
        #expect(live.phrases.map(\.source) == [.microphone, .system])
    }
    @Test func stoppingMakesFinalizedTextDurableWithoutManualAdoption() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Stopped")
        store.recordingID = id
        store.liveTranscript.begin(
            meetingID: id, language: "en", directory: store.directory(for: id),
            sources: [.microphone], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        store.liveTranscript.finalizeDetachedSession(
            token: token,
            work: {
                store.liveTranscript.receive(
                    .init(
                        session: UUID(), source: .microphone, start: 1, end: 2,
                        text: "Final phrase"), final: true, token: token)
                return true
            }, cancel: nil)
        await store.stopRecording(transcribeAfter: false)
        let reopened = MeetingStore(dataDirectory: root)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        let saved = try #require(reopened.meeting(id: id))
        #expect(saved.transcript.first?.text == "Final phrase")
        #expect(saved.transcript.first?.speaker == "mic")
        #expect(saved.speakers.count == 1)
        #expect(saved.speakers.first?.personID == nil)
        #expect(try LiveTranscriptDraft.read(at: store.directory(for: id), meetingID: id)?.phrases.count == 1)
    }
    @Test func existingEditsStayUntilExplicitRecoveryAndRevisionIsKept() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Edited")
        var meeting = try #require(store.meetings.first)
        meeting.transcript = [.init(speaker: "Editor", text: "Keep my edit")]
        await store.updateMeeting(meeting)
        let live = draft(id)
        #expect(!(await store.adoptLiveTranscript(live)))
        #expect(store.meetings.first?.transcript == meeting.transcript)
        #expect(await store.adoptLiveTranscript(live, replacing: true))
        #expect(store.meetings.first?.transcript == live.segments)
        #expect(
            try TranscriptRevisions.read(at: store.directory(for: id)).revisions.first?.segments == meeting.transcript)
        #expect(try TranscriptStorage.read(at: store.directory(for: id)) == live.segments)
    }
    @Test func emptyForeignAndPendingDraftsDoNotChangeTranscript() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Pending")
        #expect(!(await store.adoptLiveTranscript(.init(meetingID: id, locale: "en"))))
        #expect(!(await store.adoptLiveTranscript(draft(UUID()))))
        var meeting = try #require(store.meetings.first)
        meeting.transcriptionAttempt = .init(provider: .init(kind: .runpod), meeting: meeting)
        await store.updateMeeting(meeting)
        #expect(!(await store.adoptLiveTranscript(draft(id), replacing: true)))
        #expect(store.meetings.first?.transcriptionAttempt != nil)
        #expect(store.meetings.first?.transcript.isEmpty == true)
    }
    @Test func checkpointRecoveryMakesTextUsableAndDoesNotUndoALaterClear() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Interrupted recording")
        let live = draft(id)
        try live.save(at: store.directory(for: id))
        let reopened = MeetingStore(dataDirectory: root)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        var adopted = try #require(reopened.meeting(id: id))
        #expect(adopted.transcript == live.segments)
        #expect(adopted.liveTranscriptAdopted)
        adopted.transcript = []
        await reopened.updateMeeting(adopted)
        let cleared = MeetingStore(dataDirectory: root)
        #expect(await cleared.ensureMeetingLoaded(id: id))
        #expect(cleared.meeting(id: id)?.transcript.isEmpty == true)
        #expect(cleared.meeting(id: id)?.liveTranscriptAdopted == true)
        #expect(try TranscriptStorage.read(at: store.directory(for: id)).isEmpty)
        #expect(try LiveTranscriptDraft.read(at: store.directory(for: id), meetingID: id) == nil)
        #expect(try JSONDecoder().decode(Meeting.self, from: Data("{}".utf8)).liveTranscriptAdopted == false)
    }
    @Test func failedMetadataSaveKeepsOriginalAndRecoverableLiveFile() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Storage failure")
        let live = draft(id)
        try live.save(at: store.directory(for: id))
        let index = store.directory(for: id).appendingPathComponent("metadata.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(!(await store.adoptLiveTranscript(live)))
        #expect(store.meetings.first?.transcript.isEmpty == true)
        #expect(try TranscriptStorage.read(at: store.directory(for: id)) == live.segments)
    }
    @Test func explicitProviderChoiceDoesNotChangeDefaultOrPendingDestination() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var first = ServiceProvider(kind: .gdayWebsite)
        first.name = "First"
        first.endpoint = "https://first.example"
        first.enabledCapabilities = [.transcription]
        var second = first
        second.id = UUID()
        second.name = "Second"
        second.endpoint = "https://second.example"
        store.settings.serviceProviders = [first, second]
        store.settings.transcriptionProviderID = first.id
        let id = await store.createMeeting(title: "Manual choice")
        var meeting = try #require(store.meetings.first)
        #expect(store.eligibleTranscriptionProviders.map(\.id) == [first.id, second.id])
        #expect(try store.transcriptionProvider(for: meeting, providerID: second.id).id == second.id)
        #expect(store.settings.transcriptionProviderID == first.id)
        meeting.transcriptionAttempt = .init(provider: second, meeting: meeting)
        await store.updateMeeting(meeting)
        #expect(try store.transcriptionProvider(for: meeting).id == second.id)
        #expect(throws: (any Error).self) { try store.transcriptionProvider(for: meeting, providerID: first.id) }
        await #expect(throws: (any Error).self) { try await store.transcribeWithProvider(id: id, provider: first) }
        #expect(store.meetings.first?.transcriptionAttempt?.providerID == second.id)
        #expect(store.settings.transcriptionProviderID == first.id)
    }
}
