import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingFolderDateTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func dateUsesLocalGregorianDayAndPreservesIdentity() throws {
        let id = MeetingIdentity.newID()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-30T16:30:00Z"))
        let name = MeetingFolderLocation.name(
            id: id, date: date, timeZone: try #require(TimeZone(identifier: "Australia/Melbourne")))
        #expect(name == "20261001_" + MeetingIdentity.string(id))
        #expect(MeetingFolderLocation.identity(name) == id)
        #expect(MeetingFolderLocation.identity(MeetingIdentity.string(id)) == id)
        #expect(MeetingFolderLocation.identity("20261001_extra_" + MeetingIdentity.string(id)) == nil)
        #expect(MeetingFolderLocation.identity("abcdefgh_" + MeetingIdentity.string(id)) == nil)
        #expect(MeetingIdentity.parse(name) == nil)
    }

    @Test func newFolderUsesMeetingDateAndDoesNotRenameAfterDateEdit() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Synthetic meeting", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        #expect(folder.lastPathComponent == MeetingFolderLocation.name(id: meeting.id, date: meeting.createdAt))
        meeting.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try MeetingFolderStorage.write(meeting, directory: root)
        #expect(MeetingFolderStorage.folder(id: meeting.id, directory: root) == folder)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: root).createdAt == meeting.createdAt)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("meetings").path).count == 1
        )
    }

    @Test func mixedFoldersSurviveDiscoveryRebuildReadsAndEdits() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Meeting(title: "Older folder")
        let dated = Meeting(title: "Dated folder")
        for (meeting, name) in [
            (old, MeetingIdentity.string(old.id)), (dated, "20000101_" + MeetingIdentity.string(dated.id)),
        ] {
            let folder = root.appendingPathComponent("meetings").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(MeetingListEntry(meeting)).write(
                to: folder.appendingPathComponent("metadata.json"))
            try Data("Synthetic notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
            #expect(try LibraryFolderImport.adopt(folder, root: root) == nil)
        }
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count() == 2)
        #expect(index.lastRebuildErrorCount == 0)
        for meeting in [old, dated] {
            let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
            var read = try MeetingFolderStorage.read(id: meeting.id, directory: root)
            #expect(read.id == meeting.id)
            #expect(read.notes == "Synthetic notes")
            read.title = "Edited title"
            try MeetingFolderStorage.write(read, directory: root)
            try index.reconcile(paths: [folder.appendingPathComponent("metadata.json")])
            #expect(try index.entry(id: meeting.id)?.title == "Edited title")
            #expect(MeetingFolderStorage.folder(id: meeting.id, directory: root) == folder)
            try FileManager.default.removeItem(at: folder)
            try index.reconcile(paths: [folder])
            #expect(try index.entry(id: meeting.id) == nil)
        }
    }

    @Test func archiveImportUsesOriginalMeetingDateAndNewIdentity() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Meeting(title: "Imported archive", createdAt: Date(timeIntervalSince1970: 1_500_000_000))
        let file = root.appendingPathComponent("archive.json")
        try JSONEncoder().encode(original).write(to: file)
        let store = MeetingStore(dataDirectory: root)
        try await store.importArchive(url: file)
        let imported = try #require(store.meetings.first)
        #expect(imported.id != original.id)
        #expect(imported.createdAt == original.createdAt)
        #expect(
            store.directory(for: imported.id).lastPathComponent
                == MeetingFolderLocation.name(id: imported.id, date: original.createdAt))
    }

    @Test func archiveDateSurvivesReservationEvictionWhileWaitingForSave() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let existingID = await store.createMeeting(title: "Existing meeting")
        let gate = ArchiveSaveGate()
        defer { gate.release() }
        store.canonicalWriteHook = { gate.enter() }
        var existing = try #require(store.meeting(id: existingID))
        existing.title = "Updated meeting"
        let earlierSave = Task { await store.updateMeeting(existing) }
        try #require(try await waitForMainActorTestCondition { gate.started })
        store.canonicalWriteHook = nil
        var original = Meeting(title: "Imported archive", createdAt: Date(timeIntervalSince1970: 1_500_000_000))
        original.notes = "Imported notes"
        let file = root.appendingPathComponent("archive.json")
        try JSONEncoder().encode(original).write(to: file)
        let importing = Task { try await store.importArchive(url: file) }
        try #require(try await waitForMainActorTestCondition { store.meetings.contains { $0.id != existingID } })
        let imported = try #require(store.meetings.first { $0.id != existingID })
        let expected = root.appendingPathComponent("meetings").appendingPathComponent(
            MeetingFolderLocation.name(id: imported.id, date: original.createdAt))
        #expect(FileManager.default.fileExists(atPath: expected.path))
        MeetingFolderLocation.forget(id: imported.id, directory: root)
        gate.release()
        #expect(await earlierSave.value)
        try await importing.value
        #expect(store.directory(for: imported.id) == expected)
        #expect(try String(contentsOf: expected.appendingPathComponent("notes.md"), encoding: .utf8) == original.notes)
        #expect(try MeetingFolderStorage.read(id: imported.id, directory: root).createdAt == original.createdAt)
    }

    @Test func reservedRecordingPathStaysStableAcrossMidnight() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Recording", createdAt: Date(timeIntervalSince1970: 1_500_000_000))
        let folder = try MeetingFolderLocation.newFolder(id: meeting.id, date: meeting.createdAt, directory: root)
        #expect(MeetingFolderStorage.folder(id: meeting.id, directory: root, date: Date()).path == folder.path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("microphone.opus"))
        try MeetingFolderStorage.write(meeting, directory: root)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("microphone.opus").path))
        #expect(MeetingFolderStorage.folder(id: meeting.id, directory: root).path == folder.path)
    }

    @Test func monitorPathsKeepTheCallersLibraryRoot() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Synthetic path alias")
        try MeetingFolderStorage.write(meeting, directory: root)
        let physicalRoot = root.resolvingSymlinksInPath()
        let index = try LibraryIndex(directory: physicalRoot)
        try index.rebuild()
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        #expect(folder.path.hasPrefix(root.path + "/"))
        var transaction = LibraryFileTransaction(root: root)
        try transaction.remember(folder.appendingPathComponent("metadata.json"))
        try transaction.commit()
    }

    @Test func legacyImportUsesSourceMeetingDate() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy/session")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": "Synthetic import", "created_at": "2020-09-13T12:00:00Z",
        ])
        try metadata.write(to: source.appendingPathComponent("metadata.json"))
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("native"))
        #expect(try await store.importLegacyLibrary(url: source) == 1)
        let meeting = try #require(store.meetings.first)
        #expect(
            store.directory(for: meeting.id).lastPathComponent
                == MeetingFolderLocation.name(id: meeting.id, date: meeting.createdAt))
        #expect(try Data(contentsOf: source.appendingPathComponent("metadata.json")) == metadata)
    }
}

private final class ArchiveSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var started: Bool { lock.withLock { entered } }
    func enter() {
        lock.withLock { entered = true }
        semaphore.wait()
    }
    func release() { semaphore.signal() }
}
