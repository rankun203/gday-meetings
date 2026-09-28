import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LibraryFormatTests {
    private struct Entity: Codable, Identifiable, Equatable {
        var id = UUID()
        var name = "Entity"
    }

    @Test func entityCopiesAndMismatchedNamesFailWithoutChangingFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = Entity()
        try FileEntityStorage.save([record], previous: [], kind: "people", directory: root)
        let folder = root.appendingPathComponent("people")
        let original = folder.appendingPathComponent(record.id.uuidString + ".json")
        let copy = folder.appendingPathComponent(UUID().uuidString + ".json")
        let bytes = try Data(contentsOf: original)
        try bytes.write(to: copy)
        #expect(throws: (any Error).self) {
            try FileEntityStorage.load(Entity.self, kind: "people", directory: root)
        }
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try Data(contentsOf: copy) == bytes)
        try FileManager.default.removeItem(at: copy)
        #expect(try FileEntityStorage.load(Entity.self, kind: "people", directory: root) == [record])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func archiveStatusFollowsCheckpoint() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MeetingStore(dataDirectory: url)
        let archived = store.createMeeting(title: "Archived")
        let incomplete = store.createMeeting(title: "Incomplete")
        let none = store.createMeeting(title: "Local only")
        for id in [archived, incomplete] {
            try FileManager.default.createDirectory(at: store.directory(for: id), withIntermediateDirectories: true)
        }
        try UIPreview.writeArchiveFixture(store: store, id: archived, verified: true)
        // A checkpoint from before `verifiedAt` existed decodes as incomplete.
        let legacy =
            #"{"origin":"https://archive.example.com","externalID":"x","importKey":"k","snapshot":"e30=","audio":[]}"#
        try Data(legacy.utf8).write(to: store.archiveCheckpointURL(for: incomplete))
        let reopened = MeetingStore(dataDirectory: url)
        _ = reopened.ensureMeetingLoaded(id: archived)
        _ = reopened.ensureMeetingLoaded(id: incomplete)
        reopened.refreshArchiveStatuses()
        guard case .archived(let host, let date) = reopened.archiveStatuses[archived] else {
            Issue.record("Expected an archived status")
            return
        }
        #expect(host == "meetings.example.invalid")
        #expect(date != nil)
        #expect(reopened.archiveStatuses[incomplete] == .incomplete(host: "archive.example.com"))
        #expect(reopened.archiveStatuses[none] == nil)
        #expect(MeetingArchiveStatus.incomplete(host: "archive.example.com").title == "Archive incomplete")
        #expect(
            MeetingArchiveStatus.incomplete(host: "archive.example.com").accessibilityText
                == "Archive to archive.example.com incomplete. Choose Archive to Server to resume.")
        #expect(
            MeetingArchiveStatus.archived(host: "archive.example.com", date: nil).title
                == "Archived on archive.example.com")
    }
}
