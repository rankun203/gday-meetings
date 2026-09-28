import Foundation
import Testing

@testable import GdayMeetings

struct ManagedTaskJournalTests {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tasks.jsonl")
    }
    private func row(_ title: String, date: TimeInterval = 10) -> ManagedTaskRecord {
        ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: title, createdAt: Date(timeIntervalSince1970: date))
    }

    @Test func eventsAppendLatestRowsAndTombstonesWithoutRewritingCommittedBytes() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        var first = row("First")
        try journal.upsert(first)
        let prefix = try Data(contentsOf: url)
        first.state = .completed
        try journal.upsert(first)
        let second = row("Second", date: 20)
        try journal.upsert(second)
        try journal.delete(first.id)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.starts(with: prefix))
        #expect(bytes.filter { $0 == 10 }.count == 4)
        let replay = ManagedTaskJournal(url: url)
        #expect(try replay.load() == [second])
        #expect(replay.latestOffsets[first.id] == nil)
        #expect(replay.latestOffsets[second.id] != nil)
    }

    @Test func cursorOrdersByCreationAndRemainsStableAcrossUpdates() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        var rows = (0..<5).map { row("Task \($0)", date: Double($0)) }
        for task in rows { try journal.upsert(task) }
        rows[0].state = .failed
        try journal.upsert(rows[0])
        let first = journal.page(limit: 2)
        #expect(first.map(\.meetingTitle) == ["Task 4", "Task 3"])
        let cursor = ManagedTaskJournal.Cursor(createdAt: first[1].createdAt, id: first[1].id)
        #expect(journal.page(after: cursor, limit: 2).map(\.meetingTitle) == ["Task 2", "Task 1"])
        #expect(journal.page(limit: 5).last?.id == rows[0].id)
    }

    @Test func tornTailIsIgnoredAndOnlyUncommittedSuffixIsRemoved() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        let first = row("Committed")
        try journal.upsert(first)
        let prefix = try Data(contentsOf: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"schemaVersion":1,"record":"#.utf8))
        try handle.close()
        let replay = ManagedTaskJournal(url: url)
        #expect(try replay.load() == [first])
        let second = row("After recovery", date: 20)
        try replay.upsert(second)
        #expect(try Data(contentsOf: url).starts(with: prefix))
        #expect(try ManagedTaskJournal(url: url).load().count == 2)
    }

    @Test func completeMalformedLineBlocksWritesWithoutChangingFile() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = Data("{not-json}\n".utf8)
        try data.write(to: url)
        let journal = ManagedTaskJournal(url: url)
        #expect(throws: (any Error).self) { try journal.load() }
        #expect(throws: (any Error).self) { try journal.upsert(row("Must not append")) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func externalChangeAfterTornTailReplayCannotBeTruncated() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{torn".utf8).write(to: url)
        let journal = ManagedTaskJournal(url: url)
        #expect(try journal.load().isEmpty)
        let external = Data("{torn plus externally appended bytes".utf8)
        try external.write(to: url)
        #expect(throws: (any Error).self) { try journal.upsert(row("Unsafe append")) }
        #expect(try Data(contentsOf: url) == external)
    }

    @Test func unregisteredTaskKindRemainsReadable() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ManagedTaskJournal(url: url)
        var future = row("Future task")
        future.kind = .init(rawValue: "futureExport")
        try journal.upsert(future)
        let replayed = try ManagedTaskJournal(url: url).load()
        #expect(replayed.first?.kind.rawValue == "futureExport")
    }
}
