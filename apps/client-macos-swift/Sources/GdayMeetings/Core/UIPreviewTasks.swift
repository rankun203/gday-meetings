import Foundation

extension UIPreview {
    /// Opt-in fixture exercises multiple disk pages without starting provider work.
    @MainActor static func seedPagedTasks(_ store: MeetingStore) async throws {
        let requested =
            ProcessInfo.processInfo.environment["GDAY_PREVIEW_TASK_HISTORY_COUNT"].flatMap(Int.init)
            ?? (Bundle.main.object(forInfoDictionaryKey: "GdayPreviewTaskHistoryCount") as? Int) ?? 0
        guard enabled, requested > 0 else { return }
        let count = min(requested, 10_000)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let meetingID = store.meetings.first?.id ?? UUID()
        for index in 0..<count {
            let row = ManagedTaskRecord(
                kind: index.isMultiple(of: 2) ? .summary : .transcription,
                meetingID: meetingID, meetingTitle: "Completed task \(index + 1)",
                providerName: "Preview Provider", state: .completed, progress: "Completed",
                createdAt: date.addingTimeInterval(-Double(index * 60)),
                finishedAt: date.addingTimeInterval(-Double(index * 60) + 30), recovery: .none)
            try store.managedTaskJournal.upsert(row)
        }
        try await store.restoreManagedTasks()
    }
}

extension UIPreview {
    /// Finite local-only activity for checking alert-list stability during maintenance.
    @MainActor static func startTaskRefreshPreview(_ store: MeetingStore) {
        guard enabled,
            ProcessInfo.processInfo.arguments.contains("--synthetic-task-refresh")
                || Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticTaskRefresh") as? Bool == true
        else { return }
        Task { @MainActor in
            let ids = store.managedTasks.filter { $0.isPreview && $0.isMaintenance }.map(\.id)
            store.updateSearchMaintenanceBatch()
            for step in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                for id in ids {
                    guard let index = store.managedTasks.firstIndex(where: { $0.id == id }) else { continue }
                    let previous = store.managedTasks[index]
                    var current = previous
                    current.state = step == 59 ? .completed : .running
                    current.progress = step == 59 ? "Completed" : "Indexing passage \(step + 1) of 60"
                    store.managedTasks[index] = current
                    store.invalidateTaskHistory(previous: previous, current: current)
                    store.managedTaskRevision += 1
                }
            }
            let keys = Set(store.managedTasks.filter { ids.contains($0.id) }.map(\.key))
            store.backgroundJobs.removeAll { keys.contains($0.key) }
            store.updateSearchMaintenanceBatch(scanActive: false)
        }
    }
}
