import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct PassagePeopleLifecycleTests {
    @Test func pagedMergeUpdatesScopedReviewAndUndoOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let source = await store.addPerson(name: "Original contact")
        let target = await store.addPerson(name: "Kept contact")
        let id = await store.createMeeting(title: "Passage merge fixture")
        var meeting = try #require(store.meeting(id: id))
        let label = MeetingSpeaker(label: "Speaker 1", track: "system", providerName: "Fixture", personID: source)
        meeting.speakers = [label]
        let row = TranscriptSegment(
            start: 1, end: 3, speaker: label.label, text: "Reviewed words", speakerID: label.id,
            source: .system, personID: source)
        meeting.transcript = [row]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: source))
        store.clearLoadedMeetingCache()
        let merged = await store.mergePerson(id: source, into: target)
        try #require(merged, Comment(rawValue: store.errorMessage ?? "Merge failed"))
        #expect(await store.ensureMeetingLoaded(id: id))
        let loaded = try #require(store.meeting(id: id))
        let scoped = try #require(loaded.speakers.first { $0.id == loaded.transcript.first?.speakerID })
        #expect(scoped.personID == target)
        #expect(scoped.passageAssignmentOrigin?.personID == target)
        #expect(scoped.passageAssignmentOrigin?.speakerPersonID == target)
        #expect(loaded.speakerName(for: loaded.transcript[0], people: store.people) == "Kept contact")
        #expect(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: nil, restore: true))
        let restored = try #require(store.meeting(id: id))
        #expect(restored.transcript[0].speakerID == label.id)
        #expect(restored.transcript[0].personID == target)
        #expect(restored.speakers.count == 1)
    }

    @Test func deletedContactCannotReturnThroughPassageUndoAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Removed contact")
        let id = await store.createMeeting(title: "Passage deletion fixture")
        var meeting = try #require(store.meeting(id: id))
        let label = MeetingSpeaker(label: "Speaker 1", track: "system", providerName: "Fixture", personID: person)
        meeting.speakers = [label]
        let row = TranscriptSegment(
            start: 1, end: 3, speaker: label.label, text: "Reviewed words", speakerID: label.id,
            source: .system, personID: person)
        meeting.transcript = [row]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: person))
        store.clearLoadedMeetingCache()
        await store.deletePerson(id: person)
        #expect(!store.people.contains { $0.id == person })
        let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await reopened.libraryMonitor?.stop()
        reopened.libraryMonitor = nil
        #expect(await reopened.assignTranscriptPassage(meetingID: id, rowID: row.id, personID: nil, restore: true))
        let restored = try #require(reopened.meeting(id: id))
        #expect(restored.transcript[0].personID == nil)
        #expect(restored.speakers.allSatisfy { $0.personID != person })
        #expect(restored.speakerName(for: restored.transcript[0], people: reopened.people) == label.label)
    }
}
