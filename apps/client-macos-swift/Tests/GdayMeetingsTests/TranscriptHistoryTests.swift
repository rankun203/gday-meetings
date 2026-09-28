import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptHistoryTests {
    @Test func switchingVersionsKeepsIdentityCountAndEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "History")
        var meeting = try #require(store.meeting(id: id))
        let first = TranscriptSource(
            id: UUID(), providerName: "RunPod A", generatedAt: Date(timeIntervalSince1970: 100))
        let second = TranscriptSource(
            id: UUID(), providerName: "RunPod B", generatedAt: Date(timeIntervalSince1970: 200))
        meeting.transcriptSource = first
        meeting.transcript = [.init(text: "First")]
        #expect(store.updateMeeting(meeting))
        #expect(store.preserveTranscript(meeting))
        meeting.transcriptSource = second
        meeting.transcript = [.init(text: "Second")]
        #expect(store.updateMeeting(meeting))
        for _ in 0..<4 {
            let saved = try TranscriptRevisions.read(at: store.directory(for: id)).revisions
            let current = try #require(store.meeting(id: id))
            let choices = TranscriptRevisions.choices(saved, current: current)
            #expect(choices.count == 2)
            let other = try #require(choices.first { $0.id != current.transcriptSource?.id })
            store.restoreTranscript(other, meetingID: id)
        }
        var edited = try #require(store.meeting(id: id))
        edited.transcript[0].text = "Edited second"
        #expect(store.updateMeeting(edited))
        var choices = TranscriptRevisions.choices(
            try TranscriptRevisions.read(at: store.directory(for: id)).revisions, current: edited)
        store.restoreTranscript(try #require(choices.first { $0.id == first.id }), meetingID: id)
        choices = TranscriptRevisions.choices(
            try TranscriptRevisions.read(at: store.directory(for: id)).revisions,
            current: try #require(store.meeting(id: id)))
        store.restoreTranscript(try #require(choices.first { $0.id == second.id }), meetingID: id)
        #expect(store.meeting(id: id)?.transcript.first?.text == "Edited second")
        #expect(store.meeting(id: id)?.transcriptSource == second)
        var third = try #require(store.meeting(id: id))
        #expect(store.preserveTranscript(third))
        third.transcriptSource = .init(
            id: UUID(), providerName: "RunPod B", generatedAt: Date(timeIntervalSince1970: 300))
        #expect(store.updateMeeting(third))
        #expect(
            TranscriptRevisions.choices(
                try TranscriptRevisions.read(at: store.directory(for: id)).revisions, current: third
            ).count == 3)
    }
    @Test func repeatedLiveSelectionRetainsVersionAndGenerationTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Live")
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.accept(.init(session: UUID(), source: .microphone, start: 0, end: 1, text: "Live text"))
        try draft.save(at: store.directory(for: id))
        #expect(store.adoptLiveTranscript(draft))
        let source = try #require(store.meeting(id: id)?.transcriptSource)
        #expect(source.providerName == "This Mac")
        #expect(store.adoptLiveTranscript(draft, replacing: true))
        #expect(store.meeting(id: id)?.transcriptSource == source)
        var providerVersion = try #require(store.meeting(id: id))
        providerVersion.transcriptSource = .init(id: UUID(), providerName: "RunPod", generatedAt: Date())
        #expect(store.updateMeeting(providerVersion))
        #expect(store.adoptLiveTranscript(draft, replacing: true))
        #expect(store.meeting(id: id)?.transcriptSource == source)
        #expect(try TranscriptRevisions.read(at: store.directory(for: id)).revisions.count == 1)
    }
}
