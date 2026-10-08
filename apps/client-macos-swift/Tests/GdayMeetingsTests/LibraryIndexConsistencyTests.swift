import CSQLite
import CoreServices
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LibraryIndexConsistencyTests {
    private func sql(_ sql: String, root: URL, countUpdates: Bool = false) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("index.db").path, &database) == SQLITE_OK else {
            throw MeetingError.message("Couldn’t open the test index.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MeetingError.message(String(cString: sqlite3_errmsg(database)))
        }
        guard countUpdates else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM update_log", -1, &statement, nil) == SQLITE_OK else {
            throw MeetingError.message(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MeetingError.message(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    @Test func failedIncrementalUpdatesPreserveCommittedSearchAndRelationships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let tag = UUID()
        var meeting = Meeting(title: "Original title")
        meeting.personIDs = [person]
        meeting.tagIDs = [tag]
        meeting.transcript = [TranscriptSegment(text: "searchableoriginal")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let original = try #require(try index.entry(id: meeting.id))
        meeting.title = "Replacement title"
        meeting.personIDs = [UUID()]
        meeting.tagIDs = [UUID()]
        meeting.transcript = [TranscriptSegment(text: "searchablereplacement")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let transcript = folder.appendingPathComponent(TranscriptStorage.filename)
        let valid = try Data(contentsOf: transcript)
        try Data("{broken\n".utf8).write(to: transcript)
        #expect(throws: (any Error).self) { try index.reconcile(paths: [transcript]) }
        #expect(try index.entry(id: meeting.id) == original)
        #expect(try index.page(query: "searchableoriginal").map(\.id) == [meeting.id])
        #expect(try index.count(personID: person) == 1)
        #expect(try index.count(tagID: tag) == 1)

        try valid.write(to: transcript)
        // Fail after metadata, search, and relationship deletion have all run.
        _ = try sql(
            "CREATE TRIGGER reject_relation BEFORE INSERT ON relations BEGIN SELECT RAISE(ABORT,'test failure'); END;",
            root: root)
        #expect(throws: (any Error).self) { try index.upsert(MeetingListEntry(meeting), folder: folder) }
        #expect(try index.entry(id: meeting.id) == original)
        #expect(try index.page(query: "searchableoriginal").map(\.id) == [meeting.id])
        #expect(try index.page(query: "searchablereplacement").isEmpty)
        #expect(try index.count(personID: person) == 1)
        #expect(try index.count(tagID: tag) == 1)
        #expect(try index.folderName(id: meeting.id) == folder.lastPathComponent)
        _ = try sql("DROP TRIGGER reject_relation", root: root)
        try index.reconcile(paths: [transcript])
        #expect(try index.entry(id: meeting.id)?.title == meeting.title)
        #expect(try index.page(query: "searchablereplacement").map(\.id) == [meeting.id])
        #expect(try index.count(tagID: tag) == 0)
    }

    @Test func failedRemovalAndQuarantinePreserveCommittedRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Removal fixture")
        let tag = UUID()
        meeting.tagIDs = [tag]
        meeting.transcript = [TranscriptSegment(text: "retainedsearchterm")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        _ = try sql(
            "CREATE TRIGGER reject_delete BEFORE DELETE ON relations BEGIN SELECT RAISE(ABORT,'test failure'); END;",
            root: root)
        #expect(throws: (any Error).self) { try index.remove(id: meeting.id) }
        #expect(try index.count() == 1)
        #expect(try index.page(query: "retainedsearchterm").map(\.id) == [meeting.id])
        #expect(try index.count(tagID: tag) == 1)
        _ = try sql(
            "DROP TRIGGER reject_delete; CREATE TRIGGER reject_quarantine BEFORE INSERT ON meeting_folders BEGIN SELECT RAISE(ABORT,'test failure'); END;",
            root: root)
        #expect(throws: (any Error).self) { try index.quarantine(id: meeting.id) }
        #expect(try index.count() == 1)
        #expect(try index.page(query: "retainedsearchterm").map(\.id) == [meeting.id])
        #expect(try index.count(tagID: tag) == 1)
        #expect(try index.folderName(id: meeting.id) == folder.lastPathComponent)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: root).title == meeting.title)
    }

    @Test func eventBatchIndexesEachFolderOnceAndSkipsUnindexedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Event fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        _ = try sql(
            "CREATE TABLE update_log(id TEXT); CREATE TRIGGER count_updates AFTER UPDATE ON meetings BEGIN INSERT INTO update_log VALUES(new.id); END;",
            root: root)
        let names = [
            "metadata.json", "notes.md", "summary.md", TranscriptStorage.filename,
            LiveTranscriptProjection.checkpointName, "metadata.json",
        ]
        try Data("Changed note".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try index.reconcile(paths: names.map { folder.appendingPathComponent($0) } + [folder])
        #expect(try sql("SELECT 1", root: root, countUpdates: true) == 1)
        try index.reconcile(
            paths: ["audio.opus", "content.json", "attachments/notes.md", "events.jsonl"].map {
                folder.appendingPathComponent($0)
            })
        #expect(try sql("SELECT 1", root: root, countUpdates: true) == 1)
        try index.reconcile(paths: [folder.appendingPathComponent(LiveTranscriptProjection.checkpointName)])
        #expect(try sql("SELECT 1", root: root, countUpdates: true) == 1)
    }

    private final class ReconciliationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        private var errors: [String] = []
        func report(_ error: String?) {
            lock.lock()
            defer { lock.unlock() }
            if let error { errors.append(error) }
        }
        var reportedErrors: [String] {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }
        func append(_ rebuilt: Bool) {
            lock.lock()
            defer { lock.unlock() }
            values.append(rebuilt)
        }
        var first: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return values.first
        }
    }

    @Test(arguments: [false, true])
    func coordinatorAncestorEventsDiscoverAndRemoveMeetings(libraryRootEvent: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = Meeting(title: "Previous fixture")
        try MeetingFolderStorage.write(removed, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        try FileManager.default.removeItem(at: MeetingFolderStorage.folder(id: removed.id, directory: root))
        let incoming = root.appendingPathComponent("meetings/Incoming fixture")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let added = Meeting(title: "Imported fixture")
        try JSONEncoder().encode(MeetingListEntry(added)).write(to: incoming.appendingPathComponent("metadata.json"))
        // Start from a completed index and event cursor, without requesting an initial scan.
        try JSONEncoder().encode(FSEventsGetCurrentEventId()).write(
            to: root.appendingPathComponent(".index-events.json"))
        let result = ReconciliationResult()
        let coordinator = LibraryMonitorCoordinator(
            root: root, report: { _, _, _, _, _ in }, changed: { result.append($0) })
        let watchedRoot = LibraryFileMonitor.canonicalRoot(root)
        coordinator.process(
            .init(
                paths: [libraryRootEvent ? watchedRoot : watchedRoot.appendingPathComponent("meetings")],
                requiresScan: false, eventID: 0))
        let reconciled = try await waitForMainActorTestCondition(timeout: .seconds(5)) { result.first != nil }
        await coordinator.stop()
        #expect(reconciled)
        #expect(result.first == true)
        #expect(try index.page().map(\.id) == [added.id])
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(try index.folderName(id: removed.id) == nil)
    }

    @Test func nestedProviderEventsStayWithinOwningMeeting() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = LibraryFileMonitor.canonicalRoot(temporary)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Embedding fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let nested = folder.appendingPathComponent("providers/local/embeddings/source")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let artifact = nested.appendingPathComponent("clip.json")
        try Data("{}".utf8).write(to: artifact)
        let looseFile = root.appendingPathComponent("meetings/readme.txt")
        try Data("Fixture".utf8).write(to: looseFile)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        try JSONEncoder().encode(FSEventsGetCurrentEventId()).write(
            to: root.appendingPathComponent(".index-events.json"))
        let result = ReconciliationResult()
        let coordinator = LibraryMonitorCoordinator(
            root: root, report: { _, _, _, _, error in result.report(error) },
            changed: { result.append($0) })
        coordinator.process(.init(paths: [artifact, nested, looseFile], requiresScan: false, eventID: 0))
        await coordinator.stop()
        #expect(result.first == nil)
        #expect(result.reportedErrors.isEmpty)
        #expect(try index.page().map(\.id) == [meeting.id])
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func rebuildRepairsRelationsEvenWhenDocumentsMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Relation fixture")
        let tag = UUID()
        meeting.tagIDs = [tag]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        _ = try sql("DELETE FROM relations", root: root)
        #expect(try index.count(tagID: tag) == 0)
        #expect(try index.rebuild())
        #expect(try index.count(tagID: tag) == 1)
        #expect(try !index.rebuild())
    }

    @Test func recordingAudioEventDoesNotNotifyIndexOrDocumentConsumers() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = LibraryFileMonitor.canonicalRoot(temporary)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Recording fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        try JSONEncoder().encode(FSEventsGetCurrentEventId()).write(
            to: root.appendingPathComponent(".index-events.json"))
        let callbacks = ReconciliationResult()
        let coordinator = LibraryMonitorCoordinator(
            root: root, report: { _, _, _, _, error in callbacks.report(error) },
            changed: { callbacks.append($0) },
            directoryChanged: { _, _ in callbacks.append(false) },
            documentsChanged: { _, _ in callbacks.append(false) })
        let audio = MeetingFolderStorage.folder(id: meeting.id, directory: root).appendingPathComponent("audio.wav")
        coordinator.process(.init(paths: [audio], requiresScan: false, eventID: 0))
        await coordinator.stop()
        #expect(callbacks.first == nil)
        #expect(callbacks.reportedErrors.isEmpty)
    }

    @Test func reconciliationSkipsIdenticalMetadataButIndexesChangedSearchContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Unchanged fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        #expect(try index.rebuild())
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let metadata = folder.appendingPathComponent("metadata.json")
        #expect(try !index.reconcile(paths: [metadata]))
        #expect(try !index.rebuild())
        #expect(try !index.reconcile(paths: [folder.appendingPathComponent("audio.wav")]))
        let notes = folder.appendingPathComponent("notes.md")
        try Data("Changed search text".utf8).write(to: notes)
        #expect(try index.reconcile(paths: [notes]))
        #expect(try !index.reconcile(paths: [notes]))
        meeting.duration = 15
        try MeetingFolderStorage.write(meeting, directory: root)
        #expect(try index.reconcile(paths: [metadata]))
        #expect(try index.entry(id: meeting.id)?.duration == 15)
        try FileManager.default.removeItem(at: folder)
        #expect(try index.reconcile(paths: [folder]))
        #expect(try !index.reconcile(paths: [folder]))
    }

    @Test func deletedFolderEventPreservesPhysicalRootSpelling() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = LibraryFileMonitor.canonicalRoot(temporary)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Physical path fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        try FileManager.default.removeItem(at: folder)
        // FSEvents retains /private even after the folder disappears.
        try index.reconcile(paths: [folder])
        #expect(try index.count() == 0)
        #expect(try index.folderName(id: meeting.id) == nil)
    }

    @Test func ancestorEventsRemoveStaleRowsAndDiscoverNewMeetings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var removed = Meeting(title: "Removed fixture")
        let tag = UUID()
        removed.tagIDs = [tag]
        removed.transcript = [TranscriptSegment(text: "removedsearchterm")]
        try MeetingFolderStorage.write(removed, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        try FileManager.default.removeItem(at: MeetingFolderStorage.folder(id: removed.id, directory: root))
        let added = Meeting(title: "Added fixture")
        try MeetingFolderStorage.write(added, directory: root)
        let meetings = root.appendingPathComponent("meetings")
        try index.reconcile(paths: [meetings, meetings, meetings.appendingPathComponent("irrelevant")])
        #expect(try index.page().map(\.id) == [added.id])
        #expect(try index.count(tagID: tag) == 0)
        #expect(try index.page(query: "removedsearchterm").isEmpty)
        #expect(try index.folderName(id: removed.id) == nil)
        try FileManager.default.removeItem(at: meetings)
        try index.reconcile(paths: [root])
        #expect(try index.count() == 0)
    }
}
