import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LibraryFormatTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func savedVersion(_ url: URL) throws -> Int? {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url.appendingPathComponent("library.json")))
        return (object as? [String: Any])?["version"] as? Int
    }

    @Test func currentAndUnversionedLibrariesLoadAndSaveKeepsVersion() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("library.json")
        // Written before the version key existed.
        try Data(#"{"meetings":[{"title":"Old"}]}"#.utf8).write(to: file)
        let store = MeetingStore(dataDirectory: url)
        #expect(store.errorMessage == nil)
        #expect(store.meetings.map(\.title) == ["Old"])
        store.createMeeting(title: "New")
        #expect(try savedVersion(url) == MeetingLibrary.currentVersion)
        let reopened = MeetingStore(dataDirectory: url)
        #expect(reopened.libraryWritable)
        reopened.deleteMeeting(id: try #require(reopened.meetings.first { $0.title == "Old" }).id)
        #expect(try savedVersion(url) == MeetingLibrary.currentVersion)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("library-v1-backup.json").path))
    }

    @Test func newerLibraryIsRefusedAndNeverWritten() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("library.json")
        // A future layout that this build cannot decode must still report the version.
        let content = Data(#"{"version":\#(MeetingLibrary.currentVersion + 1),"meetings":"future"}"#.utf8)
        try content.write(to: file)
        let store = MeetingStore(dataDirectory: url)
        #expect(store.newerLibraryVersion == MeetingLibrary.currentVersion + 1)
        #expect(store.errorMessage == NewerLibraryVersionError.message)
        #expect(!store.libraryWritable)
        store.errorMessage = nil
        store.createMeeting(title: "Blocked")
        _ = store.addPerson(name: "Blocked")
        _ = store.addTag(name: "Blocked")
        store.saveContextChat(key: "tag", messages: [ChatMessage(content: "Blocked")])
        #expect(!store.saveSettings())
        #expect(store.errorMessage == NewerLibraryVersionError.message)
        #expect(throws: (any Error).self) { try store.insertImportedMeeting(Meeting(title: "Blocked")) }
        await #expect(throws: (any Error).self) { try await store.importAudioFiles([file]) }
        #expect(try Data(contentsOf: file) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["library.json"])
    }

    @Test func olderLibraryIsBackedUpThenMigrated() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("library.json")
        let content = Data(#"{"version":1,"meetings":[{"title":"Before"}]}"#.utf8)
        try content.write(to: file)
        let loaded = try MeetingLibrary.load(
            from: file, supportedVersion: 2, migrations: [1: { $0.meetings[0].title = "After" }])
        #expect(loaded.migrated)
        #expect(loaded.library.version == 2)
        #expect(loaded.library.meetings.map(\.title) == ["After"])
        #expect(try Data(contentsOf: url.appendingPathComponent("library-v1-backup.json")) == content)
        #expect(try Data(contentsOf: file) == content)
        // A version with no migration step is refused instead of guessed.
        #expect(throws: (any Error).self) { try MeetingLibrary.load(from: file, supportedVersion: 3, migrations: [:]) }
        let current = try MeetingLibrary.load(from: file)
        #expect(current.migrated)
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
