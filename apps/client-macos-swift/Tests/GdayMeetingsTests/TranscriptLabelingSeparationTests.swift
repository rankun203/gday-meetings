import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptLabelingSeparationTests {
    private func source() -> TranscriptSource {
        .init(id: UUID(), providerName: "This Mac", generatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func repeatedLabelingKeepsOneTextSourceAndSeparateSnapshots() {
        var meeting = Meeting()
        meeting.transcriptSource = source()
        meeting.transcript = [.init(start: 0, end: 1, text: "A synthetic line")]
        let baseline = TranscriptRevisions.current(meeting)
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Local Labeler", generatedAt: Date())
        let first = TranscriptRevisions.current(meeting)
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Local Labeler", generatedAt: Date())
        let revisions = [baseline, first]
        #expect(TranscriptRevisions.choices(revisions, current: meeting).count == 1)
        #expect(TranscriptRevisions.labelingChoices(revisions, current: meeting).count == 3)
        #expect(TranscriptRevisions.current(meeting).source == baseline.source)
        #expect(TranscriptRevisions.current(meeting).id != first.id)
    }

    @Test func legacyMatchingLabelsResolveWithoutChangingSavedSnapshots() {
        var meeting = Meeting()
        meeting.transcriptSource = source()
        meeting.transcript = [.init(start: 0, end: 1, text: "A synthetic line")]
        let original = TranscriptRevisions.current(meeting)
        let legacySource = TranscriptSource(
            id: UUID(), providerName: "Community-1 Speaker Labeling", generatedAt: Date())
        meeting.transcriptSource = legacySource
        meeting.transcript[0].speaker = "speaker_1"
        let choices = TranscriptRevisions.choices([original], current: meeting)
        #expect(choices.count == 1)
        #expect(choices.first?.source == original.source)
        #expect(choices.first?.speakerLabelSource?.resultID == legacySource.id)
        #expect(meeting.transcriptSource == legacySource)
        #expect(original.speakerLabelSource == nil)
        #expect(TranscriptRevisions.labelingChoices([original], current: meeting).count == 2)
    }

    @Test func legacyAmbiguityAndEditedTextRemainSeparate() {
        var meeting = Meeting()
        meeting.transcriptSource = source()
        meeting.transcript = [.init(start: 0, end: 1, text: "A synthetic line")]
        let original = TranscriptRevisions.current(meeting)
        meeting.transcriptSource = source()
        let second = TranscriptRevisions.current(meeting)
        meeting.transcriptSource = .init(id: UUID(), providerName: "Community-1 Speaker Labeling", generatedAt: Date())
        #expect(TranscriptRevisions.choices([original, second], current: meeting).count == 3)
        meeting.transcript[0].text = "Edited synthetic line"
        #expect(TranscriptRevisions.choices([original], current: meeting).count == 2)
    }

    @Test func labelRestorePreservesTextAndRejectsLaterEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = await store.createMeeting(title: "Synthetic labeling")
        var meeting = try #require(store.meeting(id: id))
        meeting.transcriptSource = source()
        meeting.transcript = [.init(start: 0, end: 1, speaker: "Original", text: "A synthetic line")]
        #expect(await store.updateMeeting(meeting))
        let baseline = TranscriptRevisions.current(meeting)
        #expect(store.preserveTranscript(meeting))
        meeting.transcript[0].speaker = "speaker_1"
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Local Labeler", generatedAt: Date())
        #expect(await store.updateMeeting(meeting))
        let labeled = TranscriptRevisions.current(meeting)
        #expect(await store.restoreSpeakerLabels(baseline, meetingID: id))
        #expect(store.meeting(id: id)?.transcript[0].text == "A synthetic line")
        #expect(store.meeting(id: id)?.speakerLabelSource == nil)
        #expect(await store.restoreSpeakerLabels(labeled, meetingID: id))
        var edited = try #require(store.meeting(id: id))
        edited.transcript[0].text = "Keep this edit"
        #expect(await store.updateMeeting(edited))
        #expect(!(await store.restoreSpeakerLabels(baseline, meetingID: id)))
        #expect(store.meeting(id: id)?.transcript[0].text == "Keep this edit")
        #expect(store.meeting(id: id)?.speakerLabelSource == labeled.speakerLabelSource)
    }

    @Test func editedLabelingSnapshotsKeepWholeTranscriptRecovery() {
        var meeting = Meeting()
        meeting.transcriptSource = source()
        meeting.transcript = [.init(start: 0, end: 1, text: "Before editing")]
        let baseline = TranscriptRevisions.current(meeting)
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Local Labeler", generatedAt: Date())
        meeting.transcript[0].text = "After editing"
        #expect(TranscriptRevisions.choices([baseline], current: meeting).count == 2)
        #expect(TranscriptRevisions.labelingChoices([baseline], current: meeting).count == 1)
    }

    @Test func oldMeetingDecodesWithoutLabelSource() throws {
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data("{}".utf8))
        #expect(meeting.speakerLabelSource == nil)
        var labeled = meeting
        labeled.speakerLabelSource = .init(resultID: UUID(), providerName: "Local Labeler", generatedAt: Date())
        #expect(
            try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(labeled)).speakerLabelSource
                == labeled.speakerLabelSource)
    }
}
