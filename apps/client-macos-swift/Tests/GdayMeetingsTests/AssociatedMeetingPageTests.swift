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
    @Test func exhaustedCursorDoesNotJumpBackToNewestPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = UUID()
        var meeting = Meeting(title: "Synthetic associated meeting")
        meeting.personIDs = [person]
        try MeetingFolderStorage.write(meeting, directory: directory)
        let index = try LibraryIndex(directory: directory)
        try index.rebuild()
        let first = try AssociatedMeetingPage.read(index: index, personID: person, tagID: nil)
        let exhausted = try AssociatedMeetingPage.read(
            index: index, personID: person, tagID: nil, after: first.entries.last)
        #expect(exhausted.entries.isEmpty)
        #expect(exhausted.total == 1)
        #expect(!exhausted.hasOlder)
    }

    @Test func continuousWindowEvictsOppositeEdgeAndCanScrollBack() {
        let entries = (0..<240).map { offset in
            MeetingListEntry(
                Meeting(title: "Meeting \(offset)", createdAt: Date(timeIntervalSince1970: Double(500 - offset))))
        }
        var window = AssociatedMeetingWindow()
        window.page = AssociatedMeetingPage(entries: Array(entries.prefix(200)), total: entries.count, hasOlder: true)
        let anchor = entries[185].id
        window.merge(
            AssociatedMeetingPage(entries: Array(entries[200..<220]), total: 240, hasNewer: true, hasOlder: true),
            backwards: false)
        #expect(window.page.entries.count == 200)
        #expect(window.page.entries.first?.id == entries[20].id)
        #expect(window.page.entries.contains { $0.id == anchor })
        #expect(window.page.hasNewer)
        window.merge(
            AssociatedMeetingPage(entries: Array(entries.prefix(20)), total: 240, hasOlder: true), backwards: true)
        #expect(window.page.entries.map(\.id) == Array(entries.prefix(200)).map(\.id))
        #expect(!window.page.hasNewer && window.page.hasOlder)
        // Repeated boundary completion must not duplicate retained row identities.
        window.merge(
            AssociatedMeetingPage(entries: Array(entries.prefix(20)), total: 240, hasOlder: true), backwards: true)
        #expect(Set(window.page.entries.map(\.id)).count == window.page.entries.count)
    }

    @Test func refreshingOlderWindowKeepsAnchorAndPicksUpAssociationChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = UUID()
        var meetings: [Meeting] = []
        for offset in 0..<30 {
            var meeting = Meeting(
                title: "Meeting \(offset)", createdAt: Date(timeIntervalSince1970: Double(1000 - offset)))
            meeting.personIDs = [person]
            try MeetingFolderStorage.write(meeting, directory: directory)
            meetings.append(meeting)
        }
        let index = try LibraryIndex(directory: directory)
        try index.rebuild()
        let anchor = MeetingListEntry(meetings[10])
        var newest = Meeting(title: "New associated meeting", createdAt: Date(timeIntervalSince1970: 2000))
        newest.personIDs = [person]
        try MeetingFolderStorage.write(newest, directory: directory)
        try index.upsert(MeetingListEntry(newest))
        let retained = try AssociatedMeetingPage.around(
            index: index, personID: person, tagID: nil, first: anchor, limit: 20)
        #expect(retained.entries.first?.id == anchor.id)
        #expect(retained.total == 31)
        meetings[10].personIDs = []
        try MeetingFolderStorage.write(meetings[10], directory: directory)
        try index.upsert(MeetingListEntry(meetings[10]))
        let removed = try AssociatedMeetingPage.around(
            index: index, personID: person, tagID: nil, first: anchor, limit: 20)
        #expect(removed.entries.first?.id == meetings[11].id)
        #expect(removed.total == 30)
        let top = try AssociatedMeetingPage.around(index: index, personID: person, tagID: nil, first: nil, limit: 20)
        #expect(top.entries.first?.id == newest.id)
    }

    @Test func indexedWindowTraversesBothDirectionsBeyondRetainedLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tag = UUID()
        let index = try LibraryIndex(directory: directory)
        var expected: [UUID] = []
        for offset in 0..<320 {
            var meeting = Meeting(
                title: "Associated meeting \(offset)", createdAt: Date(timeIntervalSince1970: Double(2000 - offset)))
            meeting.tagIDs = [tag]
            try index.upsert(MeetingListEntry(meeting), refreshSearch: false)
            expected.append(meeting.id)
        }
        var window = AssociatedMeetingWindow()
        window.page = try AssociatedMeetingPage.read(index: index, personID: nil, tagID: tag)
        var visited = Set(window.page.entries.map(\.id))
        for _ in 0..<20 where window.page.hasOlder {
            let page = try AssociatedMeetingPage.read(
                index: index, personID: nil, tagID: tag, after: window.page.entries.last)
            visited.formUnion(page.entries.map(\.id))
            window.merge(page, backwards: false)
            #expect(window.page.entries.count <= AssociatedMeetingWindow.limit)
        }
        #expect(visited == Set(expected))
        #expect(window.page.entries.last?.id == expected.last)
        #expect(!window.page.hasOlder && window.page.hasNewer)
        for _ in 0..<20 where window.page.hasNewer {
            let page = try AssociatedMeetingPage.read(
                index: index, personID: nil, tagID: tag, before: window.page.entries.first)
            window.merge(page, backwards: true)
            #expect(window.page.entries.count <= AssociatedMeetingWindow.limit)
        }
        #expect(window.page.entries.map(\.id) == Array(expected.prefix(AssociatedMeetingWindow.limit)))
        #expect(!window.page.hasNewer && window.page.hasOlder)
    }

}
