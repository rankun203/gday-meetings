import Foundation
import Testing

@testable import GdayMeetings

struct CanonicalPersonMergeCoverageTests {
    @Test(arguments: [false, true])
    func missingDerivedIndexEntryDoesNotOmitCanonicalMeeting(duplicateFolder: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Person(name: "Source")
        let target = Person(name: "Target")
        try FileEntityStorage.save([source, target], previous: [], kind: "people", directory: root)
        let index = try LibraryIndex(directory: root)
        var meetings: [Meeting] = []
        for number in 0..<2 {
            var meeting = Meeting(title: "Canonical \(number)")
            meeting.personIDs = [source.id]
            meeting.speakers = [.init(label: "Voice", track: "system", providerName: "test", personID: source.id)]
            try MeetingFolderStorage.write(meeting, directory: root)
            try index.upsert(MeetingListEntry(meeting))
            meetings.append(meeting)
        }
        // The source files remain authoritative while the disposable index lags.
        try index.remove(id: meetings[1].id)
        #expect(try index.count() == 1)
        let omittedFolder = try MeetingFolderLocation.resolve(id: meetings[1].id, directory: root)
        if duplicateFolder {
            let duplicate = root.appendingPathComponent("meetings").appendingPathComponent(
                MeetingFolderLocation.name(id: meetings[1].id, date: meetings[1].createdAt.addingTimeInterval(86400)))
            try FileManager.default.copyItem(at: omittedFolder, to: duplicate)
        }
        let result = CanonicalLibraryWriter.write(
            .init(
                current: .init(people: [target]), previous: .init(people: [source, target]), directory: root,
                personMerge: .init(sourceID: source.id, targetID: target.id), index: index, indexIsBuilding: false))
        #expect(result.committed == !duplicateFolder, Comment(rawValue: result.error ?? "No error"))
        for meeting in meetings {
            // Explicit original folder avoids a deliberately duplicated-ID lookup.
            let folder = root.appendingPathComponent("meetings").appendingPathComponent(
                MeetingFolderLocation.name(id: meeting.id, date: meeting.createdAt))
            let stored = try JSONDecoder().decode(
                Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("content.json")))
            let expected = duplicateFolder ? source.id : target.id
            #expect(stored.personIDs == [expected])
            #expect(stored.speakers.first?.personID == expected)
        }
        let storedPeople = try FileEntityStorage.load(Person.self, kind: "people", directory: root)
        #expect(Set(storedPeople.map(\.id)) == (duplicateFolder ? [source.id, target.id] : [target.id]))
        if !duplicateFolder { #expect(try index.count(personID: target.id) == 2) }
    }
}
