import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingFolderGuardTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func seed(_ meeting: Meeting, name: String, root: URL) throws -> URL {
        let folder = root.appendingPathComponent("meetings").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(MeetingListEntry(meeting)).write(to: folder.appendingPathComponent("metadata.json"))
        try Data(meeting.title.utf8).write(to: folder.appendingPathComponent("notes.md"))
        return folder
    }

    @Test func duplicateRebuildBlocksBothCopiesAndRecoversAfterRemoval() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Meeting(title: "First copy")
        var second = first
        second.title = "Second copy"
        let a = try seed(first, name: "20200101_" + MeetingIdentity.string(first.id), root: root)
        let b = try seed(second, name: "20210101_" + MeetingIdentity.string(first.id), root: root)
        let originalA = try Data(contentsOf: a.appendingPathComponent("metadata.json"))
        let originalB = try Data(contentsOf: b.appendingPathComponent("metadata.json"))
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count() == 0)
        #expect(index.lastRebuildErrorCount == 2)
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.read(id: first.id, directory: root)
        }
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.write(first, directory: root)
        }
        let notes = NotesStorage(directory: root)
        #expect(throws: MeetingFolderLocation.AccessError.self) { try notes.write(first.id, text: "Must not write") }
        let blocked = MeetingFolderStorage.folder(id: first.id, directory: root)
        #expect(blocked.path.hasPrefix("/dev/null/"))
        #expect(throws: (any Error).self) {
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        }
        #expect(try Data(contentsOf: a.appendingPathComponent("metadata.json")) == originalA)
        #expect(try Data(contentsOf: b.appendingPathComponent("metadata.json")) == originalB)
        #expect(try String(contentsOf: a.appendingPathComponent("notes.md"), encoding: .utf8) == "First copy")
        try FileManager.default.removeItem(at: b)
        try index.reconcile(paths: [b])
        #expect(try index.count() == 1)
        #expect(try MeetingFolderStorage.read(id: first.id, directory: root).title == first.title)
    }

    @Test func stagedRebuildKeepsCommittedFolderLookupAvailable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Meeting(title: "Committed fixture")
        try MeetingFolderStorage.write(original, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        var addedID = UUID()
        for number in 1..<500 {
            let meeting = Meeting(title: "Staged fixture \(number)")
            _ = try seed(meeting, name: MeetingFolderLocation.name(id: meeting.id, date: meeting.createdAt), root: root)
            addedID = meeting.id
        }
        let stagedID = addedID
        try index.rebuild { count in
            guard count == 500, index.lastCommittedCount == nil else { return }
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { completed.signal() }
                do {
                    #expect(try index.folderName(id: original.id) != nil)
                    #expect(try index.folderName(id: stagedID) == nil)
                }
                catch { Issue.record(error) }
            }
            #expect(completed.wait(timeout: .now() + 2) == .success)
        }
        #expect(try index.folderName(id: stagedID) != nil)
    }

    @Test func committedQuarantineOverridesAStalePositiveFolderCache() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Quarantine fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let original = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        try index.quarantine(id: meeting.id)
        // A previously started reader may finish after quarantine and refresh its location hint.
        MeetingFolderLocation.remember(folder, id: meeting.id, directory: root)
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.write(meeting, directory: root)
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("metadata.json")) == original)
    }

    @Test func duplicateEventCannotReplaceIndexedOrCachedMeeting() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Original")
        let original = try #require(store.meeting(id: id))
        let folder = store.directory(for: id)
        let originalBytes = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        var duplicate = original
        duplicate.title = "Conflicting copy"
        let copied = try seed(duplicate, name: "20000101_" + MeetingIdentity.string(id), root: root)
        let index = try #require(store.libraryIndex)
        #expect(throws: MeetingFolderLocation.AccessError.self) { try index.reconcile(paths: [copied]) }
        var edit = original
        edit.title = "Must not write"
        #expect(!store.updateMeeting(edit))
        #expect(store.errorMessage?.contains("Multiple folders") == true)
        #expect(try Data(contentsOf: folder.appendingPathComponent("metadata.json")) == originalBytes)
        #expect(
            try JSONDecoder().decode(
                MeetingListEntry.self, from: Data(contentsOf: copied.appendingPathComponent("metadata.json"))
            ).title == "Conflicting copy")
    }

    @Test func cachedAndIndexedSymlinkReplacementFailsClosed() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Outside target")
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let external = root.appendingPathComponent("external")
        try FileManager.default.moveItem(at: folder, to: external)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: external)
        let bytes = try Data(contentsOf: external.appendingPathComponent("metadata.json"))
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.read(id: meeting.id, directory: root)
        }
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.write(meeting, directory: root)
        }
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try index.reconcile(paths: [folder.appendingPathComponent("metadata.json")])
        }
        MeetingFolderLocation.forget(id: meeting.id, directory: root)
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.read(id: meeting.id, directory: root)
        }
        #expect(MeetingFolderStorage.folder(id: meeting.id, directory: root).path.hasPrefix("/dev/null/"))
        #expect(try Data(contentsOf: external.appendingPathComponent("metadata.json")) == bytes)
    }

    @Test func symlinkedMeetingsRootCannotCreateRecordingOrNotes() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("meetings"), withDestinationURL: external)
        let meeting = Meeting(title: "Blocked")
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderStorage.write(meeting, directory: root)
        }
        let notes = NotesStorage(directory: root)
        #expect(throws: MeetingFolderLocation.AccessError.self) { try notes.write(meeting.id, text: "Blocked") }
        #expect(throws: MeetingFolderLocation.AccessError.self) {
            try MeetingFolderLocation.newFolder(id: meeting.id, date: meeting.createdAt, directory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func indexRegistryRetainsLiveFallbackAfterTransientAndOlderIndexesClose() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var older: LibraryIndex? = try LibraryIndex(directory: root)
        let replacement = try LibraryIndex(directory: root)
        #expect(MeetingFolderLocation.registeredIndex(directory: root) === replacement)
        #expect(older != nil)
        older = nil
        #expect(MeetingFolderLocation.registeredIndex(directory: root) === replacement)
        do {
            let transient = try LibraryIndex(directory: root)
            #expect(MeetingFolderLocation.registeredIndex(directory: root) === transient)
            #expect(try transient.count() == 0)
        }
        #expect(MeetingFolderLocation.registeredIndex(directory: root) === replacement)
    }
}
