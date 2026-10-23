import Foundation
import Testing

@testable import GdayMeetings

struct MeetingPersonAssociationTests {
    @Test func tentativePassagesCountOnceAndLastCorrectionRemovesMembership() throws {
        let person = UUID()
        var meeting = Meeting(title: "Synthetic recording")
        var speaker = MeetingSpeaker(label: "Voice 1", track: "system", providerName: "Synthetic", personID: person)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 1, text: "First passage", speakerID: speaker.id),
            .init(start: 2, end: 3, text: "Second passage", speakerID: speaker.id),
        ]
        #expect(meeting.associatedPersonIDs == [person])
        #expect(MeetingListEntry(meeting).effectiveAssociatedPersonIDs == [person])
        #expect(meeting.personIDs.isEmpty)
        meeting.transcript[0].speakerID = nil
        #expect(meeting.associatedPersonIDs == [person])
        meeting.transcript[1].speakerID = nil
        #expect(meeting.associatedPersonIDs.isEmpty)
        meeting.personIDs = [person]
        #expect(meeting.associatedPersonIDs == [person])
    }

    @Test func mergingPeopleRewritesTentativeMembership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID()
        let target = UUID()
        var meeting = Meeting(title: "Synthetic recording")
        var speaker = MeetingSpeaker(label: "Voice 1", track: "system", providerName: "Synthetic", personID: source)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 1, text: "Synthetic passage", speakerID: speaker.id)]
        try MeetingFolderStorage.write(meeting, directory: root)
        var transaction = LibraryFileTransaction(root: root)
        let entry = try #require(
            PersonMerge(sourceID: source, targetID: target).rewriteStoredMeeting(
                id: meeting.id, directory: root, transaction: &transaction))
        #expect(entry.effectiveAssociatedPersonIDs == [target])
        let reopened = try MeetingFolderStorage.read(id: meeting.id, directory: root)
        #expect(reopened.associatedPersonIDs == [target])
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count(personID: target) == 1)
        #expect(try index.count(personID: source) == 0)
    }

    @Test func uncertainSourcePassagesRequireExplicitAssignment() {
        let person = UUID()
        var meeting = Meeting(title: "Synthetic recording")
        var speaker = MeetingSpeaker(label: "Voice 1", track: "system", providerName: "Synthetic", personID: person)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 1, text: "Unresolved passage", speakerID: speaker.id)
        ]
        meeting.transcript[0].source = .system
        meeting.transcript[0].associationUncertain = true
        #expect(meeting.associatedPersonIDs.isEmpty)
        speaker.manuallyAssigned = true
        meeting.speakers = [speaker]
        #expect(meeting.associatedPersonIDs == [person])
    }

    @Test func legacyMetadataRemainsDiscoverableWhenContentIsDamaged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let meeting = Meeting(title: "Synthetic recording", personIDs: [person])
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        var entry = MeetingListEntry(meeting)
        entry.associatedPersonIDs = nil
        try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("metadata.json"))
        try Data("Damaged content".utf8).write(to: folder.appendingPathComponent("content.json"))
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count() == 1)
        #expect(try index.count(personID: person) == 1)
        #expect(try index.page(personID: person).map(\.id) == [meeting.id])
        #expect(throws: (any Error).self) { try MeetingFolderStorage.read(id: meeting.id, directory: root) }
    }

    @Test(arguments: [false, true])
    func indexRebuildAndCorrectionPreserveExplicitAttendees(legacyMetadata: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let attendee = UUID()
        var meeting = Meeting(title: "Synthetic recording", personIDs: [attendee])
        var speaker = MeetingSpeaker(label: "Voice 1", track: "system", providerName: "Synthetic", personID: person)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 1, text: "First passage", speakerID: speaker.id),
            .init(start: 2, end: 3, text: "Second passage", speakerID: speaker.id),
        ]
        try MeetingFolderStorage.write(meeting, directory: root)
        let metadata = MeetingFolderStorage.folder(id: meeting.id, directory: root).appendingPathComponent(
            "metadata.json")
        if legacyMetadata {
            var entry = MeetingListEntry(meeting)
            entry.associatedPersonIDs = nil
            try JSONEncoder().encode(entry).write(to: metadata)
        }
        let originalMetadata = try Data(contentsOf: metadata)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count(personID: person) == 1)
        #expect(try index.count(personID: attendee) == 1)
        #expect(try index.page(personID: person).map(\.id) == [meeting.id])
        #expect(try Data(contentsOf: metadata) == originalMetadata)
        meeting.transcript[0].speakerID = nil
        try MeetingFolderStorage.write(meeting, directory: root)
        try index.upsert(MeetingListEntry(meeting))
        #expect(try index.count(personID: person) == 1)
        meeting.transcript[1].speakerID = nil
        try MeetingFolderStorage.write(meeting, directory: root)
        try index.upsert(MeetingListEntry(meeting))
        #expect(try index.count(personID: person) == 0)
        #expect(try index.count(personID: attendee) == 1)
        let reopened = try MeetingFolderStorage.read(id: meeting.id, directory: root)
        #expect(reopened.associatedPersonIDs == [attendee])
        try index.rebuild()
        #expect(try index.count(personID: person) == 0)
        #expect(try index.count(personID: attendee) == 1)
    }
}
