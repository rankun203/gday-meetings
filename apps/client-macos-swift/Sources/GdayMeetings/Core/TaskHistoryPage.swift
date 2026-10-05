import Foundation

enum TaskHistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case active = "Active"
    case attention = "Needs Attention"
    case history = "History"
    var id: String { rawValue }
    var predicate: String {
        switch self {
        case .all: "1"
        case .active: "state IN ('queued','running')"
        case .attention: "state='failed'"
        case .history: "state IN ('completed','cancelled')"
        }
    }
    func includes(_ task: ManagedTaskRecord) -> Bool {
        switch self {
        case .all: true
        case .active: task.state.isActive
        case .attention: task.state == .failed
        case .history: task.state == .completed || task.state == .cancelled
        }
    }
    func includes(_ job: VoicePreparationJob) -> Bool {
        switch self {
        case .all: true
        case .active: job.state == .queued || job.state == .running
        case .attention: job.state == .failed || job.state == .paused
        case .history: job.state == .completed
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
