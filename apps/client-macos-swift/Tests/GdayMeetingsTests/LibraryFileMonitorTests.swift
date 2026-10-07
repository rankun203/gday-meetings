import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

@Suite struct LibraryFileMonitorTests {
    @Test func excludesIndexButIncludesAllAuthoritativeKinds() {
        for path in [
            "index.db", "index.db-wal", ".index-events.json", "cache/audio", "tasks-index.sqlite",
            "tasks-index.sqlite-wal", "tasks-index.sqlite-shm", "tasks-index.sqlite-journal",
        ] {
            #expect(!LibraryFileMonitor.isRelevant(relativePath: path))
        }
        for path in [
            "meetings/ab/cd/example/notes.md", "people/person.json", "tags/tag.json", "tasks.jsonl", "settings.json",
        ] {
            #expect(LibraryFileMonitor.isRelevant(relativePath: path))
        }
    }

    @Test func audioOnlyFolderGetsMetadataAndCanonicalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = root.appendingPathComponent("meetings/Team planning")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: incoming.appendingPathComponent("audio.wav"))
        let result = try LibraryFolderImport.adopt(incoming, root: root, settleInterval: 0)
        let adopted = try #require(result)
        let entry = try JSONDecoder().decode(
            MeetingListEntry.self, from: Data(contentsOf: adopted.appendingPathComponent("metadata.json")))
        #expect(entry.title == "Team planning")
        #expect(entry.audioFiles == ["audio.wav"])
        #expect(adopted.path == MeetingFolderStorage.folder(id: entry.id, directory: root).path)
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
    }

    @Test func malformedMetadataIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("{broken".utf8)
        try original.write(to: root.appendingPathComponent("metadata.json"))
        try Data().write(to: root.appendingPathComponent("audio.wav"))
        #expect(throws: (any Error).self) { try LibraryFolderImport.adopt(root, root: root, settleInterval: 0) }
        #expect(try Data(contentsOf: root.appendingPathComponent("metadata.json")) == original)
    }
    @MainActor @Test func watchesAudioDropAndIndexesDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let finishedInitialScan = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".index-events.json").path)
                && !store.libraryDataStatus.isBuilding
        }
        #expect(finishedInitialScan)
        let incoming = root.appendingPathComponent("meetings/New audio")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let file = try AVAudioFile(
                forWriting: incoming.appendingPathComponent("audio.wav"), settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            for i in 0..<8000 { buffer.floatChannelData![0][i] = 0 }
            try file.write(from: buffer)
        }
        let discovered = try await waitForMainActorTestCondition(timeout: .seconds(10), maximumWallTime: .seconds(35)) {
            store.visibleMeetingEntries.contains { $0.title == "New audio" && $0.duration > 0 }
        }
        #expect(discovered)
        #expect(store.managedTasks.isEmpty)
        #expect(store.libraryDataStatus.meetingCount == 1)
        let discoveredID = try #require(store.visibleMeetingIDs.first)
        #expect(await store.ensureMeetingLoaded(id: discoveredID))
        #expect(store.meeting(id: discoveredID) != nil)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: store.directory(for: discoveredID), to: staging.appendingPathComponent("removed-meeting"))
        let removed = try await waitForMainActorTestCondition(timeout: .seconds(6), maximumWallTime: .seconds(25)) {
            !store.visibleMeetingIDs.contains(discoveredID) && !store.meetings.contains { $0.id == discoveredID }
        }
        #expect(removed)
        #expect(store.libraryDataStatus.meetingCount == 0)
    }

    @MainActor @Test func externalQueuedTaskRequiresResumeAndOwnWritesDoNotReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "External task")
        let external = ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl"))
        let record = ManagedTaskRecord(kind: .transcription, meetingID: id, meetingTitle: "External task")
        try external.upsert(record)
        #expect(store.managedTaskJournal.hasExternalChanges)
        await store.reloadExternalManagedTasks()
        #expect(store.managedTasks.first?.state == .paused)
        #expect(store.managedTasks.first?.recovery == .manual)
        #expect(store.managedTaskOperations.isEmpty)
        #expect(!store.managedTaskJournal.hasExternalChanges)
    }

    @MainActor @Test func initialIndexGrowthPreservesRowsAndReopensPaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var first = Meeting()
        first.title = "First committed batch"
        first.createdAt = Date(timeIntervalSince1970: 100)
        try MeetingFolderStorage.write(first, directory: root)
        try store.libraryIndex?.upsert(MeetingListEntry(first))
        store.refreshMeetingPageAvailabilityAfterIndexCommit()
        #expect(store.visibleMeetingIDs == [first.id])
        #expect(!store.hasMoreMeetings)
        for date: TimeInterval in [50, 150] {
            var next = Meeting()
            next.createdAt = Date(timeIntervalSince1970: date)
            try MeetingFolderStorage.write(next, directory: root)
            try store.libraryIndex?.upsert(MeetingListEntry(next))
        }
        store.refreshMeetingPageAvailabilityAfterIndexCommit()
        #expect(store.visibleMeetingIDs == [first.id])
        #expect(store.hasMoreMeetings)
        #expect(store.meetingPageHasPrevious)
    }

    @MainActor @Test func externalDeletionRemovesOnlyCleanInactiveLoadedMeetings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let removed = await store.createMeeting(title: "Delete externally")
        let dirty = await store.createMeeting(title: "Keep unsaved edit")
        let dirtyPosition = try #require(store.meetings.firstIndex { $0.id == dirty })
        store.meetings[dirtyPosition].title = "Unsaved change"
        for id in [removed, dirty] {
            try FileManager.default.removeItem(at: store.directory(for: id).appendingPathComponent("metadata.json"))
        }
        let transaction = root.appendingPathComponent(".document-transaction")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        await store.reloadExternalLibraryDocuments()
        #expect(store.meetings.contains { $0.id == removed })
        try FileManager.default.removeItem(at: transaction)
        await store.reloadExternalLibraryDocuments()
        #expect(!store.meetings.contains { $0.id == removed })
        #expect(store.meetings.first { $0.id == dirty }?.title == "Unsaved change")
    }

    @MainActor @Test func malformedExternalMetadataKeepsLoadedMeetingAndReportsError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Keep malformed metadata")
        try Data("{broken".utf8).write(to: store.directory(for: id).appendingPathComponent("metadata.json"))
        await store.reloadExternalLibraryDocuments()
        #expect(store.meetings.contains { $0.id == id })
        #expect(store.libraryDataStatus.error != nil)
    }

    @Test func canonicalWatcherRootKeepsPhysicalTemporaryPath() {
        let root = LibraryFileMonitor.canonicalRoot(URL(fileURLWithPath: "/tmp"))
        #expect(root.path == "/private/tmp")
    }

}
