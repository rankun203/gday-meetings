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
