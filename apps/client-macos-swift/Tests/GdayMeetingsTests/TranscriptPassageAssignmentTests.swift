import Foundation
import Testing

@testable import GdayMeetings

struct TranscriptPassageAssignmentTests {
    @Test func reviewRoundTripRepeatedAssignmentAndUndoPreserveScope() throws {
        let firstPerson = UUID()
        let secondPerson = UUID()
        let speaker = MeetingSpeaker(
            label: "Speaker 1", track: "microphone", providerName: "Fixture",
            personID: firstPerson)
        var meeting = Meeting(title: "Passage review")
        meeting.speakers = [speaker]
        let row = TranscriptSegment(
            start: 2, end: 4, speaker: speaker.label, text: "Uncertain voice",
            speakerID: speaker.id, source: .microphone, associationUncertain: true)
        let other = TranscriptSegment(
            start: 8, end: 10, speaker: speaker.label, text: "Other voice",
            speakerID: speaker.id, source: .microphone, personID: firstPerson)
        meeting.transcript = [row, other]
        let people: Set<UUID> = [firstPerson, secondPerson]
        let assigned = try #require(
            TranscriptPassageAssignment.applying(
                to: meeting, rowID: row.id, personID: secondPerson, people: people))
        #expect(assigned.transcript[1] == other)
        #expect(assigned.transcript[0].text == row.text)
        #expect(assigned.transcript[0].start == row.start)
        #expect(assigned.transcript[0].end == row.end)
        #expect(assigned.transcript[0].associationUncertain == nil)
        #expect(assigned.speakers.last?.resolvedVoiceEmbedding == nil)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(assigned))
        let cleared = try #require(
            TranscriptPassageAssignment.applying(
                to: decoded, rowID: row.id, personID: nil, people: people))
        #expect(cleared.speakers.count == 2)
        let restored = try #require(
            TranscriptPassageAssignment.applying(
                to: cleared, rowID: row.id, personID: nil, people: people, restore: true))
        #expect(restored.transcript == meeting.transcript)
        #expect(restored.speakers == meeting.speakers)
    }

    @Test func originalPassagePersonSurvivesUndoUnlessLabelWasExplicitlyCleared() throws {
        let person = UUID()
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Fixture")
        var meeting = Meeting(title: "Independent row decision")
        meeting.speakers = [speaker]
        let row = TranscriptSegment(
            speaker: speaker.label, text: "Reviewed words", speakerID: speaker.id, personID: person)
        meeting.transcript = [row]
        var assigned = try #require(
            TranscriptPassageAssignment.applying(
                to: meeting, rowID: row.id, personID: nil, people: [person]))
        let restored = try #require(
            TranscriptPassageAssignment.applying(
                to: assigned, rowID: row.id, personID: nil, people: [person], restore: true))
        #expect(restored.transcript[0].personID == person)
        assigned.speakers[1].passageAssignmentOrigin?.labelDecisionChanged = true
        let cleared = try #require(
            TranscriptPassageAssignment.applying(
                to: assigned, rowID: row.id, personID: nil, people: [person], restore: true))
        #expect(cleared.transcript[0].personID == nil)
    }

    @Test func undoUsesCurrentLabelDecisionAndNeverRevivesDeletedPerson() throws {
        let old = UUID()
        let newer = UUID()
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Fixture", personID: old)
        var meeting = Meeting(title: "Current person wins")
        meeting.speakers = [speaker]
        let row = TranscriptSegment(
            start: 0, end: 2, speaker: speaker.label, text: "Words", speakerID: speaker.id,
            personID: old)
        meeting.transcript = [row]
        var assigned = try #require(
            TranscriptPassageAssignment.applying(
                to: meeting, rowID: row.id, personID: newer, people: [old, newer]))
        assigned.speakers[0].personID = newer
        let restored = try #require(
            TranscriptPassageAssignment.applying(
                to: assigned, rowID: row.id, personID: nil, people: [newer], restore: true))
        #expect(restored.transcript[0].personID == newer)
        let deleted = try #require(
            TranscriptPassageAssignment.applying(
                to: assigned, rowID: row.id, personID: nil, people: [], restore: true))
        #expect(deleted.transcript[0].personID == nil)
    }
}

@MainActor struct TranscriptPassagePersistenceTests {
    @Test func passageReviewSaveReopenAndFailedSaveRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Persist reviewed passage")
        let person = await store.addPerson(name: "Reviewed person")
        var meeting = try #require(store.meeting(id: id))
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Fixture")
        meeting.speakers = [speaker]
        let row = TranscriptSegment(
            start: 1, end: 3, speaker: speaker.label, text: "Original words",
            speakerID: speaker.id, source: .microphone, associationUncertain: true)
        meeting.transcript = [row]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: person))
        let assigned = try #require(store.meeting(id: id))
        #expect(assigned.transcript.first?.personID == nil)
        #expect(assigned.speakers.first { $0.id == assigned.transcript.first?.speakerID }?.personID == person)
        #expect(assigned.speakerName(for: assigned.transcript[0], people: store.people) == "Reviewed person")
        let reopened = MeetingStore(dataDirectory: root)
        await reopened.libraryMonitor?.stop()
        reopened.libraryMonitor = nil
        #expect(await reopened.ensureMeetingLoaded(id: id))
        #expect(reopened.meeting(id: id)?.transcript == assigned.transcript)
        store.canonicalWriteHook = { throw MeetingError.message("Injected passage save failure") }
        #expect(!(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: nil)))
        #expect(store.meeting(id: id)?.transcript == assigned.transcript)
        store.canonicalWriteHook = nil
        #expect(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: nil, restore: true))
        #expect(store.meeting(id: id)?.transcript == [row])
    }
}
