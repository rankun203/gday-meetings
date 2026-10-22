import Foundation

enum TaskHistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All Tasks"
    case active = "Active"
    case attention = "Needs Attention"
    case paused = "Paused"
    case failed = "Failed"
    case history = "History"
    case maintenance = "Search Index Maintenance"
    var id: String { rawValue }
    var emptyMessage: String {
        switch self {
        case .all: "No tasks in All Tasks"
        case .active: "No active tasks"
        case .attention: "No tasks need attention"
        case .paused: "No paused tasks"
        case .failed: "No failed tasks"
        case .history: "No completed or cancelled tasks"
        case .maintenance: "No search index maintenance tasks"
        }
    }
    var predicate: String {
        switch self {
        case .all: "1=1"
        case .active: "state IN ('queued','running') AND (kind!='searchIndex' OR automatic=0)"
        case .attention: "attention=1"
        case .history: "state IN ('completed','cancelled') AND (kind!='searchIndex' OR automatic=0)"
        case .paused: "state='paused'"
        case .failed: "state='failed'"
        case .maintenance: "kind='searchIndex' AND automatic=1"
        }
    }
    func includes(_ task: ManagedTaskRecord) -> Bool {
        if self == .maintenance { return task.isMaintenance }
        if self == .attention { return task.needsAttention }
        if task.isMaintenance && [.active, .history].contains(self) { return false }
        return includes(task.state)
    }
    func includes(_ state: ManagedTaskState) -> Bool {
        switch self {
        case .all: true
        case .active: state.isActive
        case .attention: false
        case .paused: state == .paused
        case .failed: state == .failed
        case .history: state == .completed || state == .cancelled
        case .maintenance: false
        }
    }
    func includes(_ job: VoicePreparationJob) -> Bool {
        switch self {
        case .all: true
        case .active: job.state == .queued || job.state == .running
        case .attention: job.needsAttention
        case .paused: job.state == .paused
        case .failed: job.state == .failed
        case .history: job.state == .completed || job.state == .cancelled
        case .maintenance: false
        }
    }
}

enum TaskHistoryRow: Identifiable, Equatable, @unchecked Sendable {
    case managed(ManagedTaskRecord)
    case voice(VoicePreparationJob)
    var id: UUID {
        switch self {
        case .managed(let row): row.id
        case .voice(let row): row.id
        }
    }
    var createdAt: Date {
        switch self {
        case .managed(let row): row.createdAt
        case .voice(let row): row.createdAt
        }
    }
    var cursor: ManagedTaskJournal.Cursor { .init(createdAt: createdAt, id: id) }
    var activityAt: Date {
        switch self {
        case .managed(let row): row.taskHistoryActivityAt
        case .voice(let row): row.taskHistoryActivityAt
        }
    }
    var displayCursor: ManagedTaskJournal.DisplayCursor { .init(activityAt: activityAt, id: id) }
    static func recentActivityFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.activityAt == rhs.activityAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.activityAt > rhs.activityAt
    }
    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }
}

extension MeetingStore {
    func taskFilterCounts() async throws -> [TaskHistoryQuery: Int] {
        let journal = managedTaskJournal
        let visibility = taskVisibilityPredicate
        let previews = visibleManagedTasks.filter(\.isPreview)
        let voices = voiceLibrary.jobs
        return try await Task.detached(priority: .utility) {
            var counts = try journal.filterCounts(where: visibility)
            for query in TaskHistoryQuery.allCases {
                counts[query, default: 0] += previews.filter(query.includes).count + voices.filter(query.includes).count
            }
            return counts
        }.value
    }

    /// Counts use the same predicates as display pages, without reading SQLite during view evaluation.
    func taskDisplayCount(scope: TaskHistoryScope, type: TaskHistoryType = .all) async -> Int {
        let query = TaskHistoryQuery(status: scope, type: type)
        let journal = managedTaskJournal
        let predicate = "(\(query.predicate)) AND (\(taskVisibilityPredicate))"
        let extras =
            visibleManagedTasks.filter { $0.isPreview && query.includes($0) }.count
            + voiceLibrary.jobs.filter(query.includes).count
        let count = await Task.detached(priority: .userInitiated) { journal.count(where: predicate) }.value
        if let failure = journal.readFailure {
            managedTaskJournalError = "Couldn’t read task history. \(failure.localizedDescription)"
        }
        return count + extras
    }

    func taskDisplayPage(
        scope: TaskHistoryScope, type: TaskHistoryType = .all,
        cursor: ManagedTaskJournal.DisplayCursor? = nil, newer: Bool = false, limit: Int = 50
    ) async -> [TaskHistoryRow] {
        let query = TaskHistoryQuery(status: scope, type: type)
        let journal = managedTaskJournal
        let predicate = "(\(query.predicate)) AND (\(taskVisibilityPredicate))"
        let extras =
            visibleManagedTasks.filter { $0.isPreview && query.includes($0) }.map(TaskHistoryRow.managed)
            + voiceLibrary.jobs.filter(query.includes).map(TaskHistoryRow.voice)
        let candidates = await Task.detached(priority: .userInitiated) {
            journal.displayPage(after: cursor, limit: limit, predicate: predicate, newer: newer).map(
                TaskHistoryRow.managed)
                + extras
        }.value
        if let failure = journal.readFailure {
            managedTaskJournalError = "Couldn’t read task history. \(failure.localizedDescription)"
        }
        // A transition may commit while disk paging is suspended. Reconcile both task
        // stores and exclude rows that crossed the requested cursor boundary.
        var result = candidates.compactMap { row -> TaskHistoryRow? in
            switch row {
            case .managed(let saved):
                let current = managedTasks.first { $0.id == saved.id } ?? saved
                return query.includes(current) && isTaskMeetingVisible(current.meetingID) ? .managed(current) : nil
            case .voice(let saved):
                guard let current = voiceLibrary.jobs.first(where: { $0.id == saved.id }), query.includes(current)
                else {
                    return nil
                }
                return .voice(current)
            }
        }
        if let cursor {
            result.removeAll { row in
                let isNewer =
                    row.activityAt > cursor.activityAt
                    || (row.activityAt == cursor.activityAt && row.id.uuidString > cursor.id.uuidString)
                return row.id == cursor.id || (newer ? !isNewer : isNewer)
            }
        }
        result.sort(by: TaskHistoryRow.recentActivityFirst)
        return newer ? Array(result.suffix(max(0, limit))) : Array(result.prefix(max(0, limit)))
    }

    /// Use the complete indexed state counts, not the retained task page window.
    func taskHistoryCount(scope: TaskHistoryScope) -> Int {
        visibleManagedTaskCount(where: scope.predicate, unfiltered: managedTaskScopeCounts[scope, default: 0])
            + visibleManagedTasks.filter { $0.isPreview && scope.includes($0) }.count
            + voiceLibrary.jobs.filter(scope.includes).count
    }

    /// Merge at most one disk page with matching voice/preview candidates. Voice payloads
    /// are still hydrated by VoiceLibraryStore; this does not duplicate its full history.
    func taskHistoryPage(
        scope: TaskHistoryScope, cursor: ManagedTaskJournal.Cursor? = nil, newer: Bool = false, limit: Int = 50
    ) async -> [TaskHistoryRow] {
        let journal = managedTaskJournal
        let predicate = "(\(scope.predicate)) AND (\(taskVisibilityPredicate))"
        let extras =
            visibleManagedTasks.filter { $0.isPreview && scope.includes($0) }.map(TaskHistoryRow.managed)
            + voiceLibrary.jobs.filter(scope.includes).map(TaskHistoryRow.voice)
        let result = await Task.detached(priority: .userInitiated) {
            var candidates = journal.page(after: cursor, limit: limit, predicate: predicate, newer: newer).map(
                TaskHistoryRow.managed)
            candidates += extras
            if let cursor {
                candidates.removeAll { row in
                    let isNewer =
                        row.createdAt > cursor.createdAt
                        || (row.createdAt == cursor.createdAt && row.id.uuidString > cursor.id.uuidString)
                    return row.id == cursor.id || (newer ? !isNewer : isNewer)
                }
            }
            candidates.sort(by: TaskHistoryRow.newestFirst)
            return newer ? Array(candidates.suffix(limit)) : Array(candidates.prefix(limit))
        }.value
        if let failure = journal.readFailure {
            managedTaskJournalError = "Couldn’t read task history. \(failure.localizedDescription)"
        }
        // Disk paging may finish after progress or a terminal transition. Keep the
        // current snapshot, removing rows that have since left this scope.
        return result.compactMap { row in
            guard case .managed(let saved) = row,
                let live = managedTasks.first(where: { $0.id == saved.id })
            else { return row }
            return scope.includes(live) ? .managed(live) : nil
        }
    }
}
