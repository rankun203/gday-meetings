import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

struct ManagedTaskPagingTests {
    @MainActor @Test func filteredTotalsUseCompleteStateCountsAndPreviewExtras() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.managedTaskStateCounts = [.queued: 2, .running: 3, .completed: 900, .failed: 4, .cancelled: 5]
        store.managedTaskAttentionCount = 4
        store.managedTaskScopeCounts = [.all: 914, .active: 5, .attention: 4, .history: 905]
        store.managedTasks = [
            .init(
                kind: .summary, meetingID: UUID(), meetingTitle: "Preview task", state: .failed, isPreview: true,
                recovery: .manual),
            .init(kind: .summary, meetingID: UUID(), meetingTitle: "Retained task", state: .completed),
        ]
        #expect(store.taskHistoryCount(scope: .all) == 915)
        #expect(store.taskHistoryCount(scope: .active) == 5)
        #expect(store.taskHistoryCount(scope: .attention) == 5)
        #expect(store.taskHistoryCount(scope: .history) == 905)
    }

    private struct Event: Encodable {
        var schemaVersion = 1
        var eventID = UUID()
        var writtenAt = Date(timeIntervalSince1970: 1)
        var operation = "upsert"
        let taskID: UUID
        let record: ManagedTaskRecord
    }
    private func fixture(tasks: Int, revisions: Int = 1) throws -> (URL, [ManagedTaskRecord]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tasks.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let records = (0..<tasks).map { index in
            ManagedTaskRecord(
                kind: .summary, meetingID: UUID(), meetingTitle: "Task \(index)", state: .completed,
                createdAt: Date(timeIntervalSince1970: Double(index / 3)))
        }
        for revision in 0..<revisions {
            for var record in records {
                record.progress = "Revision \(revision)"
                var data = try JSONEncoder().encode(Event(taskID: record.id, record: record))
                data.append(10)
                try file.write(contentsOf: data)
            }
        }
        try file.synchronize()
        return (url, records)
    }
    @Test func coldRebuildWarmReuseAndBidirectionalPaging() async throws {
        let (url, records) = try fixture(tasks: 401, revisions: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        try journal.prepare()
        #expect(journal.replayedEventCount == 1203)
        let expected = records.sorted(by: ManagedTaskJournal.newestFirst).map(\.id)
        var seen: [UUID] = []
        var cursor: ManagedTaskJournal.Cursor?
        while true {
            let page = journal.page(after: cursor, limit: 37)
            guard let last = page.last else { break }
            #expect(page.count <= 37)
            seen += page.map(\.id)
            cursor = .init(createdAt: last.createdAt, id: last.id)
        }
        #expect(seen == expected)
        let middle = journal.page(limit: 100).last!
        let previous = journal.page(after: .init(createdAt: middle.createdAt, id: middle.id), limit: 37, newer: true)
        #expect(previous.map(\.id) == Array(expected[62..<99]))
        let warm = ManagedTaskJournal(url: url)
        try warm.prepare()
        #expect(warm.replayedEventCount == 0)
        #expect(warm.page(limit: 37).map(\.id) == Array(expected.prefix(37)))
    }
    @Test func disposableIndexRemovalRebuildsWithoutChangingJournal() async throws {
        let (url, _) = try fixture(tasks: 91, revisions: 4)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let indexURL = url.deletingLastPathComponent().appendingPathComponent("custom.sqlite")
        do {
            let journal = ManagedTaskJournal(url: url, indexURL: indexURL)
            try journal.prepare()
        }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexURL.path + suffix) }
        let rebuilt = ManagedTaskJournal(url: url, indexURL: indexURL)
        try rebuilt.prepare()
        #expect(rebuilt.replayedEventCount == 364)
        #expect(rebuilt.count() == 91)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func sameLengthExternalReplacementBlocksAppend() async throws {
        let (url, records) = try fixture(tasks: 1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        try journal.prepare()
        let changed = try Data(contentsOf: url)
        try changed.write(to: url, options: .atomic)
        #expect(throws: (any Error).self) { try journal.upsert(records[0]) }
        #expect(try Data(contentsOf: url) == changed)
    }
    @Test func externalAppendOnlyMarksChangedOffsets() async throws {
        let (url, _) = try fixture(tasks: 301)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        try journal.prepare()
        let old = journal.page(limit: 301)
        let external = ManagedTaskJournal(
            url: url, indexURL: url.deletingLastPathComponent().appendingPathComponent("external.sqlite"))
        var changed = old.last!
        changed.state = .failed
        try external.upsert(changed)
        try journal.prepare()
        #expect(try journal.changedSinceRebuild(changed.id))
        for row in old.dropLast() { #expect(try !journal.changedSinceRebuild(row.id)) }
    }
    @Test func presentationOnlyExternalEditDoesNotPauseIntent() async throws {
        let (url, _) = try fixture(tasks: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        try journal.prepare()
        let original = journal.page(limit: 3)
        let target = original.first { $0.meetingTitle == "Task 1" }!
        let content = try String(contentsOf: url, encoding: .utf8)
        try Data(content.replacingOccurrences(of: "Task 1", with: "Work 1").utf8).write(to: url, options: .atomic)
        try journal.prepare()
        #expect(try !journal.changedSinceRebuild(target.id))
        for row in original where row.id != target.id { #expect(try !journal.changedSinceRebuild(row.id)) }
        #expect(journal.record(id: target.id)?.meetingTitle == "Work 1")
    }

    @Test @MainActor func progressUpdatesDoNotAppendJournalEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Progress fixture", state: .running)
        try store.managedTaskJournal.upsert(task)
        store.managedTasks = [task]
        let before = try Data(contentsOf: store.managedTaskJournal.url)
        for index in 0..<1000 { store.recordManagedTaskProgress(task.key, progress: "Step \(index)") }
        #expect(store.managedTasks.first?.progress == "Step 999")
        #expect(try Data(contentsOf: store.managedTaskJournal.url) == before)
    }

    @Test @MainActor func historyPagesDoNotHydrateOperationalCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let (url, _) = try fixture(tasks: 401)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: url, to: store.managedTaskJournal.url)
        try await store.restoreManagedTasks()
        #expect(store.managedTasks.count == 100)
        #expect(store.managedTaskCount == 401)
        var cursor: ManagedTaskJournal.Cursor?
        var ids = Set<UUID>()
        while true {
            let page = await store.taskHistoryPage(scope: .history, cursor: cursor)
            guard let last = page.last else { break }
            #expect(page.count <= 50)
            ids.formUnion(page.map(\.id))
            cursor = last.cursor
        }
        #expect(ids.count == 401)
        #expect(store.managedTasks.count == 100)
    }

    @Test(arguments: [false, true]) @MainActor func externalAppendReconcilesOrphanedRunningTask(receipt: Bool)
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = await store.createMeeting(title: "Orphaned operation")
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: meetingID, meetingTitle: "Orphaned operation", state: .running)
        try store.managedTaskJournal.upsert(task)
        store.managedTasks = [task]
        if receipt {
            var meeting = try #require(store.meeting(id: meetingID))
            meeting.completedTaskIDs[task.kind.rawValue] = task.id
            #expect(await store.updateMeeting(meeting))
        }
        let external = ManagedTaskJournal(
            url: store.managedTaskJournal.url, indexURL: directory.appendingPathComponent("external.sqlite"))
        try external.upsert(
            ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "External history", state: .completed))
        await store.reloadExternalManagedTasks()
        let recovered = try #require(store.managedTask(id: task.id))
        #expect(recovered.state == (receipt ? .completed : .failed))
        #expect(recovered.recovery == (receipt ? .none : .manual))
        #expect(store.managedTaskOperations.isEmpty)
        #expect(store.managedTaskStateCounts[.running, default: 0] == 0)
    }

    @Test func corruptOffsetRebuildsDisposableIndexWithoutRewritingSource() async throws {
        let (url, _) = try fixture(tasks: 5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let indexURL = url.deletingLastPathComponent().appendingPathComponent("offsets.sqlite")
        do {
            let journal = ManagedTaskJournal(url: url, indexURL: indexURL)
            try journal.prepare()
        }
        let original = try Data(contentsOf: url)
        var database: OpaquePointer?
        #expect(sqlite3_open(indexURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "UPDATE task_offsets SET offset=1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let journal = ManagedTaskJournal(url: url, indexURL: indexURL)
        try journal.prepare()
        #expect(journal.replayedEventCount == 0)
        #expect(journal.page(limit: 5).count == 5)
        #expect(journal.replayedEventCount == 5)
        #expect(journal.readFailure == nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func manyEventsDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["GDAY_TASK_HISTORY_BENCHMARK"] == "1" else { return }
        let (url, _) = try fixture(tasks: 10_000, revisions: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let cold = ManagedTaskJournal(url: url)
        let coldDuration = try clock.measure { try cold.prepare() }
        let warm = ManagedTaskJournal(url: url)
        let warmDuration = try clock.measure { try warm.prepare() }
        let pageDuration = clock.measure { _ = warm.page(limit: 50) }
        #expect(cold.replayedEventCount == 100_000)
        #expect(warm.replayedEventCount == 0)
        #expect(warm.page(limit: 50).count == 50)
        print(
            "TASK_HISTORY_BENCHMARK events=100000 tasks=10000 cold=\(coldDuration) warm=\(warmDuration) page50=\(pageDuration)"
        )
    }
}
