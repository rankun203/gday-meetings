import Foundation

/// Apply meeting visibility before task pagination. The journal and library share the
/// disposable index; neither task history nor scheduler state is changed by this filter.
enum TaskVisibility {
    static func predicate(excluding tags: Set<UUID>, loadedMeetings: [Meeting], hasLibraryIndex: Bool) -> String {
        guard !tags.isEmpty else { return "1" }
        func literals(_ ids: [UUID]) -> String {
            ids.map { ManagedTaskIndex.literal($0.uuidString) }.joined(separator: ",")
        }
        let hidden = loadedMeetings.filter { !tags.isDisjoint(with: $0.tagIDs) }.map(\.id)
        var clauses: [String] = []
        if !hidden.isEmpty { clauses.append("meeting NOT IN (\(literals(hidden)))") }
        if hasLibraryIndex {
            // Hydrated metadata can be newer than its derived library entry.
            let loaded = loadedMeetings.map(\.id)
            let override = loaded.isEmpty ? "" : "meeting IN (\(literals(loaded))) OR "
            clauses.append(
                "(\(override)NOT EXISTS (SELECT 1 FROM main.relations hidden WHERE hidden.meeting=task_offsets.meeting AND hidden.kind='tag' AND hidden.target IN (\(literals(Array(tags))))))"
            )
        }
        return clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
    }
}

/// Presentation caches follow both task and relationship revisions. This avoids repeated
/// synchronous index reads during SwiftUI body evaluation without retaining meeting payloads.
final class TaskVisibilityCache {
    struct MeetingTags: Equatable {
        var id: UUID
        var tags: [UUID]
    }
    struct Key: Equatable {
        var excluded: Set<UUID>
        var meetings: [MeetingTags]
        var libraryRevision: UUID
        var taskRevisions: [TaskHistoryScope: Int]
        var scopeCounts: [TaskHistoryScope: Int]
    }
    var key: Key?
    var counts: [String: Int] = [:]
    var meetings: [UUID: Bool] = [:]
    func prepare(_ key: Key) {
        guard self.key != key else { return }
        self.key = key
        counts.removeAll(keepingCapacity: true)
        meetings.removeAll(keepingCapacity: true)
    }
}

extension MeetingStore {
    private func prepareTaskVisibilityCache() {
        taskVisibilityCache.prepare(
            .init(
                excluded: excludedTagIDs,
                meetings: meetings.map { .init(id: $0.id, tags: $0.tagIDs) },
                libraryRevision: meetingIndexRevision, taskRevisions: managedTaskScopeRevisions,
                scopeCounts: managedTaskScopeCounts))
    }

    var taskVisibilityPredicate: String {
        TaskVisibility.predicate(
            excluding: excludedTagIDs, loadedMeetings: meetings, hasLibraryIndex: libraryIndex != nil)
    }

    func isTaskMeetingVisible(_ id: UUID) -> Bool {
        guard !excludedTagIDs.isEmpty else { return true }
        prepareTaskVisibilityCache()
        if let visible = taskVisibilityCache.meetings[id] { return visible }
        let tagIDs = meeting(id: id)?.tagIDs ?? (try? libraryIndex?.entry(id: id))?.tagIDs ?? []
        let visible = excludedTagIDs.isDisjoint(with: tagIDs)
        taskVisibilityCache.meetings[id] = visible
        return visible
    }

    var visibleManagedTasks: [ManagedTaskRecord] {
        managedTasks.filter { isTaskMeetingVisible($0.meetingID) }
    }

    func visibleManagedTaskCount(where predicate: String, unfiltered: Int) -> Int {
        guard !excludedTagIDs.isEmpty else { return unfiltered }
        prepareTaskVisibilityCache()
        if let count = taskVisibilityCache.counts[predicate] { return count }
        let count = managedTaskJournal.count(where: "(\(predicate)) AND (\(taskVisibilityPredicate))")
        taskVisibilityCache.counts[predicate] = count
        return count
    }
}
