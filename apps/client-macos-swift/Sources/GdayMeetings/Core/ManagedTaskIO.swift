import Foundation

/// Blocking journal and SQLite operations share a serial queue, never the UI executor.
final class ManagedTaskIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gdaymeetings.task-journal", qos: .utility)
    private let beforeOperation: @Sendable () throws -> Void

    init(beforeOperation: @escaping @Sendable () throws -> Void = {}) {
        self.beforeOperation = beforeOperation
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [beforeOperation] in
                do {
                    try beforeOperation()
                    continuation.resume(returning: try operation())
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Keeps each read/transition/commit command ordered across suspension points.
/// A started command finishes even if its caller stops waiting; cancellation is
/// an explicit subsequent command, not an interrupted journal write.
@MainActor final class ManagedTaskCommands {
    private var tail: Task<Void, Never>?
    private(set) var pending = 0
    var isIdle: Bool { pending == 0 }

    func run<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        pending += 1
        let work = Task { @MainActor in
            await previous?.value
            let value = await operation()
            pending -= 1
            return value
        }
        tail = Task { @MainActor in _ = await work.value }
        return await work.value
    }

    func drain() async {
        while pending > 0 { await tail?.value }
    }
}

struct ManagedTaskSnapshot: Sendable {
    var recent: [ManagedTaskRecord]
    var maintenanceCounts: [ManagedTaskState: Int]
    var scopeCounts: [TaskHistoryScope: Int]
    var attentionCount: Int
    var counts: [ManagedTaskState: Int]
    var activeCounts: [BackgroundJob.Key: Int]
    var activeIDs: Set<UUID>

    static func read(_ journal: ManagedTaskJournal) throws -> Self {
        let recent = journal.page(limit: 100)
        if let failure = journal.readFailure { throw failure }
        let counts = Dictionary(
            uniqueKeysWithValues: ManagedTaskState.allCases.map {
                ($0, journal.count(where: "state=" + ManagedTaskIndex.literal($0.rawValue)))
            })
        // Keep keys/counts for all active work, but hydrate only one page at a time.
        var activeCounts: [BackgroundJob.Key: Int] = [:]
        var activeIDs = Set<UUID>()
        var cursor: ManagedTaskJournal.Cursor?
        while true {
            let page = journal.page(after: cursor, limit: 50, predicate: "state IN ('queued','running')")
            if let failure = journal.readFailure { throw failure }
            for record in page {
                activeCounts[record.key, default: 0] += 1
                activeIDs.insert(record.id)
            }
            guard page.count == 50, let last = page.last else { break }
            cursor = .init(createdAt: last.createdAt, id: last.id)
        }
        return Self(
            recent: recent,
            maintenanceCounts: Dictionary(
                uniqueKeysWithValues: [ManagedTaskState.queued, .running, .paused].map {
                    (
                        $0,
                        journal.count(
                            where: "kind='searchIndex' AND automatic=1 AND state="
                                + ManagedTaskIndex.literal($0.rawValue))
                    )
                }),
            scopeCounts: Dictionary(
                uniqueKeysWithValues: TaskHistoryScope.allCases.map { ($0, journal.count(where: $0.predicate)) }),
            attentionCount: journal.count(where: "attention=1"), counts: counts,
            activeCounts: activeCounts, activeIDs: activeIDs)
    }
}
