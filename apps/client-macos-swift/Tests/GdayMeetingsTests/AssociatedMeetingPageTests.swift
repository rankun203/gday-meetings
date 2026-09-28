import Foundation
import Testing

@testable import GdayMeetings

struct AssociatedMeetingPageTests {
    @Test func tagAndPersonPagesReachOlderMeetingsAndReturnWithoutAccumulation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tag = UUID()
        let person = UUID()
        var expected: [UUID] = []
        for number in 0..<45 {
            var meeting = Meeting(
                title: "Meeting \(number)", createdAt: Date(timeIntervalSince1970: Double(1000 - number)))
            meeting.tagIDs = [tag]
            meeting.personIDs = [person]
            try MeetingFolderStorage.write(meeting, directory: directory)
            expected.append(meeting.id)
        }
        let index = try LibraryIndex(directory: directory)
        try index.rebuild()
        for forPerson in [false, true] {
            let personID = forPerson ? person : nil
            let tagID = forPerson ? nil : tag
            let first = try AssociatedMeetingPage.read(index: index, personID: personID, tagID: tagID)
            #expect(first.total == 45)
            #expect(first.entries.map(\.id) == Array(expected.prefix(20)))
            #expect(!first.hasNewer && first.hasOlder)
            let second = try AssociatedMeetingPage.read(
                index: index, personID: personID, tagID: tagID, after: first.entries.last)
            #expect(second.entries.map(\.id) == Array(expected[20..<40]))
            #expect(second.hasNewer && second.hasOlder)
            let last = try AssociatedMeetingPage.read(
                index: index, personID: personID, tagID: tagID, after: second.entries.last)
            #expect(last.entries.map(\.id) == Array(expected.suffix(5)))
            #expect(last.hasNewer && !last.hasOlder)
            let previous = try AssociatedMeetingPage.read(
                index: index, personID: personID, tagID: tagID, before: last.entries.first)
            #expect(previous.entries.map(\.id) == second.entries.map(\.id))
            let newest = try AssociatedMeetingPage.read(
                index: index, personID: personID, tagID: tagID, before: previous.entries.first)
            #expect(newest.entries.map(\.id) == first.entries.map(\.id))
            #expect(!newest.hasNewer)
        }
    }
}
