import Foundation
import Testing

@testable import GdayMeetings

struct TaskVisibilityTests {
    @MainActor @Test func excludedTasksAreFilteredBeforePagingAndCounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let index = try LibraryIndex(
            directory: root, indexDirectory: store.managedTaskJournal.indexURL.deletingLastPathComponent())
        store.libraryIndex = index
        let excluded = MeetingTag(name: "Private", isExcluded: true)
        store.tags = [excluded]
        let visible = Meeting(title: "Visible fixture")
        let hidden = Meeting(title: "Hidden fixture", tagIDs: [excluded.id])
        for meeting in [visible, hidden] {
            try MeetingFolderStorage.write(meeting, directory: root)
            try index.upsert(MeetingListEntry(meeting))
        }
        try store.managedTaskJournal.prepare()
        var records: [ManagedTaskRecord] = []
        for number in 0..<120 {
            records.append(
                .init(
                    kind: .summary, meetingID: number.isMultiple(of: 3) ? visible.id : hidden.id,
                    meetingTitle: "Synthetic task", state: .failed,
                    createdAt: Date(timeIntervalSince1970: Double(number)), recovery: .manual))
        }
        try store.managedTaskJournal.upsertBatch(records)
        // No hydrated meetings: the complete indexed relationships must drive filtering.
        store.meetings = []
        #expect(store.taskHistoryCount(scope: .all) == 40)
        #expect(store.taskAttentionCount == 40)
        let first = await store.taskHistoryPage(scope: .all, limit: 17)
        let second = await store.taskHistoryPage(scope: .all, cursor: first.last?.cursor, limit: 17)
        let third = await store.taskHistoryPage(scope: .all, cursor: second.last?.cursor, limit: 17)
        let expected = records.filter { $0.meetingID == visible.id }.sorted(by: ManagedTaskJournal.newestFirst).map(
            \.id)
        #expect((first + second + third).map(\.id) == expected)
        let backward = await store.taskHistoryPage(scope: .all, cursor: second.first?.cursor, newer: true, limit: 17)
        #expect(backward.map(\.id) == first.map(\.id))
        #expect(!store.isTaskMeetingVisible(hidden.id))
        #expect(store.managedTaskJournal.count() == 120)

        // Unsaved relationship changes override the derived entry in both directions.
        var nowVisible = hidden
        nowVisible.tagIDs = []
        var nowHidden = visible
        nowHidden.tagIDs = [excluded.id]
        store.meetings = [nowVisible, nowHidden]
        #expect(store.taskHistoryCount(scope: .all) == 80)
        #expect(store.isTaskMeetingVisible(hidden.id))
        #expect(!store.isTaskMeetingVisible(visible.id))
    }

    @MainActor @Test func hiddenPreviewTasksDoNotShowAttentionOrActivity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let tag = MeetingTag(name: "Hidden", isExcluded: true)
        let meeting = Meeting(title: "Synthetic fixture", tagIDs: [tag.id])
        store.tags = [tag]
        store.meetings = [meeting]
        store.managedTasks = [
            .init(
                kind: .summary, meetingID: meeting.id, meetingTitle: meeting.title,
                state: .failed, isPreview: true, recovery: .manual)
        ]
        #expect(store.taskAttentionCount == 0)
        #expect(!store.showsTaskQueueStatus)
        #expect(!store.hasTaskHistory)
        #expect(store.taskQueueSummary == "No active tasks")
        store.tags[0].isExcluded = false
        #expect(store.taskAttentionCount == 1)
        #expect(store.showsTaskQueueStatus)
    }
    @MainActor @Test func hiddenPersistedActivityAndGlobalScanAreDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let tag = MeetingTag(name: "Hidden", isExcluded: true)
        let hidden = Meeting(title: "Hidden fixture", tagIDs: [tag.id])
        let visible = Meeting(title: "Visible fixture")
        store.tags = [tag]
        store.meetings = [hidden, visible]
        try store.managedTaskJournal.prepare()
        let running = ManagedTaskRecord(
            kind: .summary, meetingID: hidden.id, meetingTitle: hidden.title, state: .running)
        let queued = ManagedTaskRecord(
            kind: .transcription, meetingID: hidden.id, meetingTitle: hidden.title, state: .queued)
        try store.managedTaskJournal.upsertBatch([running, queued])
        store.managedTasks = [running, queued]
        store.managedTaskStateCounts = [.running: 1, .queued: 1]
        #expect(!store.showsTaskQueueStatus)
        #expect(store.taskQueueActivitySummary.isEmpty)
        let visibleQueued = ManagedTaskRecord(
            kind: .summary, meetingID: visible.id, meetingTitle: visible.title, state: .queued)
        try store.managedTaskJournal.upsert(visibleQueued)
        store.managedTaskScopeRevisions[.all, default: 0] += 1
        #expect(store.showsTaskQueueStatus)
        #expect(store.taskQueueActivitySummary == "1 queued")
        // A persisted transition must invalidate already-warm filtered aggregates.
        var completed = visibleQueued
        completed.state = .completed
        #expect(await store.saveManagedTask(completed))
        #expect(!store.showsTaskQueueStatus)
        #expect(store.taskQueueActivitySummary.isEmpty)
        #expect(store.taskHistoryCount(scope: .history) == 1)
        store.tags = []
        store.managedTaskStateCounts = [:]
        store.managedTasks = []
        store.searchMaintenanceBatchActive = true
        #expect(store.showsTaskQueueStatus)
        #expect(store.taskQueueActivitySummary == "Search index maintenance")
        store.tags = [tag]
        let scan = Task<Void, Never> {}
        store.localSearch.scanTask = scan
        #expect(store.visibleSearchMaintenanceBatchActive)
        store.localSearch.scanTask = nil
        #expect(!store.visibleSearchMaintenanceBatchActive)
    }

}
