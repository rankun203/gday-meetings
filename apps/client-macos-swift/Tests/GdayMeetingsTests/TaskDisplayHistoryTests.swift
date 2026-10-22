import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

struct TaskDisplayHistoryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recentTransitionsPageBothDirectionsWithoutChangingRecoveryOrder() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl"))
        var records = (0..<83).map { index in
            ManagedTaskRecord(
                kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic task", state: .completed,
                createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        records[0].state = .paused
        records[0].timeline = [.init(kind: .paused, date: Date(timeIntervalSince1970: 500), reason: nil)]
        records[1].state = .running
        records[1].timeline = [.init(kind: .resumed, date: Date(timeIntervalSince1970: 500), reason: nil)]
        for record in records { try journal.upsert(record) }
        let expected = records.map(TaskHistoryRow.managed).sorted(by: TaskHistoryRow.recentActivityFirst)
        var cursor: ManagedTaskJournal.DisplayCursor?
        var seen: [UUID] = []
        while true {
            let page = journal.displayPage(after: cursor, limit: 11)
            guard let last = page.last else { break }
            seen += page.map(\.id)
            cursor = TaskHistoryRow.managed(last).displayCursor
        }
        #expect(seen == expected.map(\.id))
        let middle = expected[35]
        let previous = journal.displayPage(after: middle.displayCursor, limit: 11, newer: true)
        #expect(previous.map(\.id) == Array(expected[24..<35]).map(\.id))
        #expect(journal.page(limit: 83).map(\.id) == records.sorted(by: ManagedTaskJournal.newestFirst).map(\.id))
        var progress = records[0]
        progress.progress = "Preparing another example"
        try journal.upsert(progress)
        #expect(journal.displayPage(limit: 83).map(\.id) == seen)
    }

    @Test func rebuildingDisplayIndexPreservesAuthoritativeJournal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tasks.jsonl")
        let indexURL = root.appendingPathComponent("index.db")
        let record = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic task", state: .paused,
            timeline: [.init(kind: .paused, date: .distantFuture, reason: nil)])
        do { try ManagedTaskJournal(url: url, indexURL: indexURL).upsert(record) }
        let before = try Data(contentsOf: url)
        var database: OpaquePointer?
        #expect(sqlite3_open(indexURL.path, &database) == SQLITE_OK)
        #expect(
            sqlite3_exec(database, "UPDATE index_modules SET version=4 WHERE namespace='core_tasks'", nil, nil, nil)
                == SQLITE_OK)
        sqlite3_close(database)
        let rebuilt = ManagedTaskJournal(url: url, indexURL: indexURL)
        try rebuilt.prepare()
        #expect(rebuilt.replayedEventCount == 1)
        #expect(rebuilt.displayPage().map(\.id) == [record.id])
        #expect(try Data(contentsOf: url) == before)
        let warm = ManagedTaskJournal(url: url, indexURL: indexURL)
        try warm.prepare()
        #expect(warm.replayedEventCount == 0)
        #expect(warm.displayPage().map(\.id) == [record.id])
    }

    @MainActor @Test func statusAndTypeFilterBeforePagingAndCountingAcrossStores() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.voiceLibrary.awaitLoaded()
        let records = (0..<121).map { index in
            ManagedTaskRecord(
                kind: index.isMultiple(of: 2) ? .summary : .searchIndex, meetingID: UUID(),
                meetingTitle: "Synthetic meeting", state: index.isMultiple(of: 3) ? .paused : .completed,
                createdAt: Date(timeIntervalSince1970: Double(index)), isAutomatic: index.isMultiple(of: 5))
        }
        try store.managedTaskJournal.upsertBatch(records)
        let preview = ManagedTaskRecord(
            kind: .searchIndex, meetingID: UUID(), meetingTitle: "Synthetic preview", state: .paused,
            isPreview: true, isAutomatic: true)
        store.managedTasks = [preview]
        let voice = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1, discover: true,
            exampleIDs: [], state: .paused)
        var preparation = voice
        preparation.id = UUID()
        preparation.discover = false
        #expect(store.voiceLibrary.setJobs([voice, preparation]))
        let menuCounts = try await store.taskFilterCounts()
        for query in TaskHistoryQuery.allCases {
            let expected =
                records.filter(query.includes).map(TaskHistoryRow.managed)
                + [preview].filter(query.includes).map(TaskHistoryRow.managed)
                + [voice, preparation].filter(query.includes).map(TaskHistoryRow.voice)
            #expect(await store.taskDisplayCount(scope: query.status, type: query.type) == expected.count)
            #expect(menuCounts[query] == expected.count)
            var cursor: ManagedTaskJournal.DisplayCursor?
            var actual: [TaskHistoryRow] = []
            while true {
                let page = await store.taskDisplayPage(scope: query.status, type: query.type, cursor: cursor, limit: 7)
                guard let last = page.last else { break }
                actual += page
                cursor = last.displayCursor
            }
            #expect(actual.map(\.id) == expected.sorted(by: TaskHistoryRow.recentActivityFirst).map(\.id))
        }
    }

    @MainActor @Test func typedRevisionsTrackEntryExitAndMaintenanceStatuses() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let previous = ManagedTaskRecord(
            kind: .searchIndex, meetingID: UUID(), meetingTitle: "Synthetic maintenance", state: .running,
            isAutomatic: true)
        var current = previous
        current.state = .paused
        store.invalidateTaskHistory(previous: previous, current: current)
        #expect(store.managedTaskDisplayRevisions[.init(status: .active)] == 1)
        #expect(store.managedTaskDisplayRevisions[.init(status: .paused)] == 1)
        #expect(store.managedTaskDisplayRevisions[.init(type: .maintenance)] == 1)
        #expect(store.managedTaskDisplayRevisions[.init(status: .all, type: .summary)] == nil)
        #expect(store.managedTaskDisplayRevisions[.init(status: .attention, type: .all)] == nil)
        let revision = store.managedTaskFilterCountRevision
        var progress = current
        progress.progress = "Preparing another example"
        store.invalidateTaskHistory(previous: current, current: progress)
        #expect(store.managedTaskFilterCountRevision == revision)
        store.invalidateTaskHistory(previous: progress, current: nil)
        #expect(store.managedTaskFilterCountRevision == revision + 1)
    }

    @Test func typeMenuContainsEveryKindInAlphabeticalOrder() {
        let values = TaskHistoryType.menuCases
        #expect(Set(values) == Set(TaskHistoryType.allCases.filter { $0 != .all }))
        #expect(
            values.map(\.rawValue)
                == values.map(\.rawValue).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                })
    }

    @Test func legacyRecordsUseCreationOrFinishedDateAndIgnoreProgressTiming() {
        var record = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic legacy task",
            createdAt: Date(timeIntervalSince1970: 10))
        #expect(record.taskHistoryActivityAt == record.createdAt)
        record.finishedAt = Date(timeIntervalSince1970: 20)
        record.timeline = [.init(kind: .waitingForProvider, date: Date(timeIntervalSince1970: 30), reason: nil)]
        #expect(record.taskHistoryActivityAt == record.finishedAt)
        #expect(TaskDescription(.managed(record)).date == record.taskHistoryActivityAt)
        let unknown = ManagedTaskRecord(
            kind: .init(rawValue: "futureKind"), meetingID: UUID(), meetingTitle: "Synthetic future task")
        #expect(TaskHistoryType.other.includes(unknown))
        #expect(!TaskHistoryType.summary.includes(unknown))
    }

    @Test func everyManagedKindUsesMatchingIndexedAndInMemoryFilters() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl"))
        let kinds: [BackgroundJob.Kind] = [
            .transcription, .diarization, .summary, .recordingFinalization, .speakerAssociation, .todoExtraction,
            .libraryIndex, .searchIndex, .chat, .archive, .contextChat, .importAudio, .init(rawValue: "futureKind"),
        ]
        let records = kinds.flatMap { kind in
            [false, true].map { automatic in
                ManagedTaskRecord(
                    kind: kind, meetingID: UUID(), meetingTitle: "Synthetic operation", state: .completed,
                    isAutomatic: automatic)
            }
        }
        try journal.upsertBatch(records)
        for type in TaskHistoryType.allCases {
            let expected = Set(records.filter(type.includes).map(\.id))
            let page = journal.displayPage(limit: 100, predicate: type.predicate)
            #expect(Set(page.map(\.id)) == expected)
            #expect(journal.count(where: type.predicate) == expected.count)
        }
    }
}
