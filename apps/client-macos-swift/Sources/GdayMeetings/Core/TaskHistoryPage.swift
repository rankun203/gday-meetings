import Foundation

enum TaskHistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case active = "Active"
    case attention = "Needs Attention"
    case paused = "Paused"
    case failed = "Failed"
    case history = "History"
    case maintenance = "Search Index Maintenance"
    var id: String { rawValue }
    var predicate: String {
        switch self {
        case .all: "(kind!='searchIndex' OR automatic=0 OR attention=1)"
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
        if task.isMaintenance && [.all, .active, .history].contains(self) {
            return self == .all && task.needsAttention
        }
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
    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }
}

extension MeetingStore {
    /// Use the complete indexed state counts, not the retained task page window.
    func taskHistoryCount(scope: TaskHistoryScope) -> Int {
        managedTaskScopeCounts[scope, default: 0]
            + managedTasks.filter { $0.isPreview && scope.includes($0) }.count
            + voiceLibrary.jobs.filter(scope.includes).count
    }

    /// Merge at most one disk page with matching voice/preview candidates. Voice payloads
    /// are still hydrated by VoiceLibraryStore; this does not duplicate its full history.
    func taskHistoryPage(
        scope: TaskHistoryScope, cursor: ManagedTaskJournal.Cursor? = nil, newer: Bool = false, limit: Int = 50
    ) async -> [TaskHistoryRow] {
        let journal = managedTaskJournal
        let extras =
            managedTasks.filter { $0.isPreview && scope.includes($0) }.map(TaskHistoryRow.managed)
            + voiceLibrary.jobs.filter(scope.includes).map(TaskHistoryRow.voice)
        let result = await Task.detached(priority: .userInitiated) {
            var candidates = journal.page(after: cursor, limit: limit, predicate: scope.predicate, newer: newer).map(
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
        return result
    }
}
