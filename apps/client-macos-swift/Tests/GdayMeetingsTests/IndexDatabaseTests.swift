import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

struct IndexDatabaseTests {
    private final class PublicationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var maximumRead = 0.0
        private var maximumWrite = 0.0
        private var failure: String?
        private var partialRead = false
        private let ready = DispatchSemaphore(value: 0)
        private let finished = DispatchGroup()

        init(url: URL) {
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { finished.leave() }
                do {
                    let connection = try IndexDatabase.open(at: url)
                    ready.signal()
                    while true {
                        lock.lock()
                        let stop = stopped
                        lock.unlock()
                        if stop { break }
                        let readStart = Date()
                        let query = try connection.prepare(
                            "SELECT count(*) FROM meetings WHERE title='Updated synthetic meeting'")
                        guard sqlite3_step(query) == SQLITE_ROW else {
                            connection.release(query)
                            throw connection.failure()
                        }
                        let count = sqlite3_column_int(query, 0)
                        connection.release(query)
                        let readTime = Date().timeIntervalSince(readStart)
                        let writeStart = Date()
                        try connection.execute("UPDATE journal_revision SET committed=committed+1 WHERE id=1")
                        let writeTime = Date().timeIntervalSince(writeStart)
                        lock.lock()
                        maximumRead = max(maximumRead, readTime)
                        maximumWrite = max(maximumWrite, writeTime)
                        partialRead = partialRead || (count != 0 && count != 20_000)
                        lock.unlock()
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                catch {
                    lock.lock()
                    failure = error.localizedDescription
                    lock.unlock()
                    ready.signal()
                }
            }
            ready.wait()
        }
        func stop() -> (read: Double, write: Double, failure: String?, partialRead: Bool) {
            lock.lock()
            stopped = true
            lock.unlock()
            finished.wait()
            return (maximumRead, maximumWrite, failure, partialRead)
        }
    }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shared-index-\(UUID())/index.db")
    }
    private func integer(_ sql: String, _ connection: IndexDatabase.Connection) throws -> Int {
        let statement = try connection.prepare(sql)
        defer { connection.release(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test func domainAdaptersShareOneDatabaseAndLeaveObsoleteCachesUntouched() throws {
        let url = location()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = Person(name: "Synthetic person")
        try FileEntityStorage.save([person], previous: [], kind: "people", directory: root)
        var meeting = Meeting(title: "Shared database fixture")
        meeting.personIDs = [person.id]
        try MeetingFolderStorage.write(meeting, directory: root)
        let oldCache = root.appendingPathComponent("tasks-index.sqlite")
        let oldBytes = Data("An obsolete synthetic cache.".utf8)
        try oldBytes.write(to: oldCache)
        let library = try LibraryIndex(directory: root)
        try library.rebuild()
        let directory = try DirectoryIndex(root: root, indexDirectory: root)
        try directory.reconcile(paths: [], rebuild: true)
        let journal = ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl"))
        let task = ManagedTaskRecord(kind: .summary, meetingID: meeting.id, meetingTitle: meeting.title)
        try journal.upsert(task)
        #expect(try journal.load() == [task])
        #expect(try directory.page(kind: .people).entries.first?.meetingCount == 1)
        #expect(try library.count() == 1)
        let connection = try IndexDatabase.open(at: url)
        #expect(try integer("SELECT count(*) FROM index_modules", connection) == 3)
        #expect(try Data(contentsOf: oldCache) == oldBytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".directory-index.db").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks.index.sqlite").path))
    }

    @Test func moduleUpgradePreservesOtherDomainsAndGuideMatchesSchema() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = try IndexDatabase.open(at: url)
        try connection.register(.library)
        try connection.register(.directory)
        try connection.register(.tasks)
        try connection.execute(
            "INSERT INTO meetings VALUES('meeting',1,-1,'Synthetic meeting',X'00'); INSERT INTO entities VALUES('people','person','Synthetic person',0); INSERT INTO journal_revision VALUES(1,'journal',0)"
        )
        let next = IndexDatabase.Module(
            namespace: "core_directory", version: 2, tables: IndexDatabase.Module.directory.tables,
            indexes: IndexDatabase.Module.directory.indexes, initialValues: IndexDatabase.Module.directory.initialValues
        )
        #expect(try connection.register(next))
        #expect(try integer("SELECT count(*) FROM entities", connection) == 0)
        #expect(try integer("SELECT count(*) FROM meetings", connection) == 1)
        #expect(try integer("SELECT count(*) FROM journal_revision", connection) == 1)
        let guide = try String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent("index.db.md"), encoding: .utf8)
        #expect(guide.contains("| core_directory | 2 |"))
        #expect(guide.contains("CREATE TABLE task_offsets"))
        #expect(!guide.contains("CREATE TABLE 'search_passages_data'"))
        #expect(!guide.contains("{{SCHEMA}}"))
    }

    @Test func stagingAllowsUnrelatedWritesAndRejectsConcurrentSameModuleWrite() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rebuilding = try IndexDatabase.open(at: url)
        try rebuilding.register(.library)
        try rebuilding.register(.tasks)
        try rebuilding.execute("INSERT INTO meetings VALUES('meeting',1,-1,'Original',X'00')")
        let concurrent = try IndexDatabase.open(at: url)
        try rebuilding.beginStaging(.library, preservingRows: true)
        try rebuilding.execute("UPDATE meetings SET title='Staged'")
        #expect(try integer("SELECT count(*) FROM meetings WHERE title='Original'", concurrent) == 1)
        try concurrent.execute("INSERT INTO journal_revision VALUES(1,'unrelated write',0)")
        try rebuilding.publishStaging()
        #expect(try integer("SELECT count(*) FROM meetings WHERE title='Staged'", concurrent) == 1)
        #expect(try integer("SELECT count(*) FROM journal_revision", concurrent) == 1)
        try rebuilding.beginStaging(.library, preservingRows: true)
        try rebuilding.execute("UPDATE meetings SET title='Stale stage'")
        try concurrent.execute("UPDATE meetings SET title='Newer change'")
        #expect(throws: (any Error).self) { try rebuilding.publishStaging() }
        rebuilding.discardStaging()
        #expect(try integer("SELECT count(*) FROM meetings WHERE title='Newer change'", concurrent) == 1)
    }

    @Test func fullTextStagingPreservesPassageIdentityAndRollback() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = try IndexDatabase.open(at: url)
        try connection.register(.library)
        try connection.execute(
            "INSERT INTO search_locations VALUES(42,'meeting','title','revision'); INSERT INTO search_passages(rowid,meeting,kind,text) VALUES(42,'meeting','title','originalneedle')"
        )
        try connection.beginStaging(.library, preservingRows: true)
        try connection.execute("UPDATE search_passages SET text='replacementneedle' WHERE rowid=42")
        try connection.publishStaging()
        #expect(
            try integer("SELECT rowid FROM search_passages WHERE search_passages MATCH 'replacementneedle'", connection)
                == 42)
        #expect(try integer("SELECT id FROM search_locations", connection) == 42)
        try connection.beginStaging(.library, preservingRows: true)
        try connection.execute("DELETE FROM search_passages")
        connection.discardStaging()
        #expect(try integer("SELECT count(*) FROM search_passages", connection) == 1)
    }

    @Test func providerNamespacesRejectInvalidOwnership() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = try IndexDatabase.open(at: url)
        let invalid = IndexDatabase.Module(
            namespace: "provider_example", version: 1, tables: [.init(name: "meetings", definition: "(id TEXT)")],
            indexes: "", initialValues: "")
        #expect(throws: (any Error).self) { try connection.register(invalid) }
        let valid = IndexDatabase.Module(
            namespace: "provider_example", version: 1,
            tables: [
                .init(
                    name: "provider_example_vectors",
                    definition: "(source TEXT PRIMARY KEY,model TEXT NOT NULL,dimensions INTEGER NOT NULL)")
            ], indexes: "", initialValues: "")
        try connection.register(valid)
        #expect(
            try integer("SELECT count(*) FROM index_module_tables WHERE namespace='provider_example'", connection) == 1)
    }

    @Test func corruptionRecoveryPreservesEvidenceAndUnmarkedGuide() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic corrupt database".utf8).write(to: url)
        let guide = url.deletingLastPathComponent().appendingPathComponent("index.db.md")
        try Data("An existing user document.".utf8).write(to: guide)
        let connection = try IndexDatabase.open(at: url)
        #expect(connection.recoveredCorruption)
        try connection.register(.library)
        #expect(try integer("SELECT count(*) FROM meetings", connection) == 0)
        #expect(try String(contentsOf: guide, encoding: .utf8) == "An existing user document.")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains {
                $0.hasPrefix("index.db.corrupt-")
            })
    }

    @Test func pendingRecoveryNeverReplacesDatabaseWhileAConnectionIsLive() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let first = try IndexDatabase.open(at: url)
            try first.register(.library)
            try first.execute("INSERT INTO meetings VALUES('meeting',1,-1,'Retained while open',X'00')")
            try Data().write(to: URL(fileURLWithPath: url.path + ".needs-recovery"))
            let second = try IndexDatabase.open(at: url)
            #expect(!second.recoveredCorruption)
            #expect(try integer("SELECT count(*) FROM meetings", second) == 1)
        }
        let recovered = try IndexDatabase.open(at: url)
        #expect(recovered.recoveredCorruption)
        try recovered.register(.library)
        #expect(try integer("SELECT count(*) FROM meetings", recovered) == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".needs-recovery"))
    }

    @Test func databaseSymlinkDoesNotModifyItsTarget() throws {
        let url = location()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("synthetic-document.txt")
        let bytes = Data("Keep this source unchanged.".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try IndexDatabase.open(at: url) }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func measuresTwentyThousandRowPublication() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = try IndexDatabase.open(at: url)
        try connection.register(.library)
        try connection.register(.tasks)
        try connection.execute(
            "WITH RECURSIVE fixture(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM fixture WHERE n<20000) INSERT INTO meetings SELECT CAST(n AS TEXT),n,-n,'Synthetic indexed meeting',X'00' FROM fixture"
        )
        try connection.beginStaging(.library, preservingRows: true)
        try connection.execute("UPDATE meetings SET title='Updated synthetic meeting'")
        let reader = try IndexDatabase.open(at: url)
        #expect(try integer("SELECT count(*) FROM meetings WHERE title='Synthetic indexed meeting'", reader) == 20_000)
        let unrelatedStart = Date()
        try reader.execute("INSERT INTO journal_revision VALUES(1,'still writable while staging',0)")
        let unrelated = Date().timeIntervalSince(unrelatedStart)
        let probe = PublicationProbe(url: url)
        defer { _ = probe.stop() }
        let start = Date()
        try connection.publishStaging()
        let publication = Date().timeIntervalSince(start)
        let stalls = probe.stop()
        #expect(stalls.failure == nil)
        #expect(!stalls.partialRead)
        #expect(try integer("SELECT count(*) FROM meetings WHERE title='Updated synthetic meeting'", reader) == 20_000)
        print(
            "Shared index fixture: 20000 metadata rows; staged unrelated write \(unrelated)s; atomic publication \(publication)s; maximum concurrent read \(stalls.read)s; maximum concurrent task write \(stalls.write)s"
        )
    }
}
