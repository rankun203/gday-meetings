import Foundation
import Testing

@testable import GdayMeetings

struct TagExclusionTests {
    @Test func olderDocumentsDefaultToIncluded() throws {
        let person = try JSONDecoder().decode(Person.self, from: Data("{}".utf8))
        let tag = try JSONDecoder().decode(MeetingTag.self, from: Data("{}".utf8))
        #expect(person.tagIDs.isEmpty)
        #expect(!tag.isExcluded)
    }

    @Test func exclusionsApplyBeforePagingAndSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let excluded = UUID()
        let shared = UUID()
        let person = UUID()
        let index = try LibraryIndex(directory: directory)
        var visible: [UUID] = []
        for number in 0..<65 {
            var meeting = Meeting(
                title: "Planning \(number)", createdAt: Date(timeIntervalSince1970: Double(1000 - number)))
            meeting.tagIDs = number.isMultiple(of: 3) ? [shared, excluded] : [shared]
            meeting.personIDs = [person]
            try MeetingFolderStorage.write(meeting, directory: directory)
            try index.upsert(MeetingListEntry(meeting))
            if !number.isMultiple(of: 3) { visible.append(meeting.id) }
        }
        let first = try index.page(query: "Planning", excludingTagIDs: [excluded])
        let second = try index.page(after: first.last, query: "Planning", excludingTagIDs: [excluded])
        let last = try index.page(after: second.last, query: "Planning", excludingTagIDs: [excluded])
        #expect(first.count == 20 && second.count == 20)
        #expect((first + second + last).map(\.id) == visible)
        #expect(try index.page(before: second.first, query: "Planning", excludingTagIDs: [excluded]) == first)
        #expect(try index.count(excludingTagIDs: [excluded]) == visible.count)
        #expect(try index.count(personID: person, excludingTagIDs: [excluded]) == visible.count)
        #expect(try index.page(tagID: shared, excludingTagIDs: [excluded]).map(\.id) == first.map(\.id))
        #expect(try index.count() == 65)
        #expect(try index.count(tagID: excluded) == 22)
    }

    @MainActor @Test func associationsAndExclusionSurviveRestartAndCanBeReversed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = store.createMeeting(title: "Planning")
        let tagID = store.addTag(name: "Project")
        let personID = store.addPerson(name: "Alex")
        let otherID = store.addPerson(name: "Taylor")
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.tagIDs = [tagID]
        meeting.personIDs = [personID, otherID]
        store.updateMeeting(meeting)
        var person = try #require(store.people.first { $0.id == personID })
        person.tagIDs = [tagID]
        store.updatePerson(person)
        var tag = try #require(store.tags.first)
        tag.isExcluded = true
        store.updateTag(tag)
        #expect(store.visibleMeetingEntries.isEmpty)
        #expect(store.listedPeople.map(\.id) == [otherID])
        #expect(store.meeting(id: meetingID) != nil)
        let restored = MeetingStore(dataDirectory: directory)
        #expect(restored.visibleMeetingEntries.isEmpty)
        #expect(restored.people.first { $0.id == personID }?.tagIDs == [tagID])
        #expect(restored.listedPeople.map(\.id) == [otherID])
        tag.isExcluded = false
        restored.updateTag(tag)
        #expect(restored.visibleMeetingEntries.map(\.id) == [meetingID])
        #expect(restored.listedPeople.count == 2)
        restored.deleteTag(id: tagID)
        let final = MeetingStore(dataDirectory: directory)
        #expect(final.people.allSatisfy { $0.tagIDs.isEmpty })
        #expect(final.meeting(id: meetingID)?.tagIDs.isEmpty == true)
    }
}
