import Foundation

/// A durable user request groups the existing per-meeting scheduler intents.
/// It does not run work independently of the managed task queue.
struct SearchIndexRebuild: Codable, Equatable {
    enum State: String, Codable { case requested, running, completed, cancelled }
    var id = UUID()
    var state: State = .requested
    var modelSpace: String?
    var meetings: [UUID]?
    var children: [UUID: UUID] = [:]
    var finished = 0
    var failed = 0
    var cancelled = 0
    var isActive: Bool { state == .requested || state == .running }
    var progress: String {
        if state == .cancelled { return "Rebuild cancelled." }
        guard let meetings else { return "Preparing rebuild…" }
        if state == .completed {
            if failed == 0 && cancelled == 0 { return "Search index rebuilt." }
            return "Rebuild finished with \(failed) failed and \(cancelled) cancelled tasks. See Tasks."
        }
        return "Rebuilding search index: \(finished) of \(meetings.count) meetings"
    }
}

extension LocalSearchController {
    func saveRebuild(_ request: SearchIndexRebuild) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: rebuildURL, options: .atomic)
        rebuildRequest = request
    }
}

extension MeetingStore {
    func cancelSearchIndexRebuild() async {
        guard var request = localSearch.rebuildRequest, request.isActive else { return }
        // Persist cancellation first, so launch recovery cannot admit more children.
        request.state = .cancelled
        do {
            try localSearch.saveRebuild(request)
            localSearch.status = request.progress
            if !((await cancelManagedTaskBatch(request.id))) {
                localSearch.error = managedTaskJournalError ?? "Couldn't cancel all rebuild tasks. Try again in Tasks."
            }
        }
        catch { localSearch.error = error.localizedDescription }
    }

    func refreshSearchIndexRebuild() async throws {
        guard let original = localSearch.rebuildRequest, original.isActive else { return }
        let tasks = try await managedTasksForBatch(original.id)
        guard var request = localSearch.rebuildRequest, request.id == original.id, request.isActive else { return }
        request.meetings = request.meetings?.filter { containsMeeting(id: $0) }
        request.finished = 0
        request.failed = 0
        request.cancelled = 0
        let latest = Dictionary(grouping: tasks, by: \.meetingID).values.compactMap {
            $0.max { $0.createdAt < $1.createdAt }
        }
        for task in latest {
            guard request.meetings?.contains(task.meetingID) == true else { continue }
            if task.state == .cancelled && !task.userStopped {
                if request.children[task.meetingID] == task.id { request.children.removeValue(forKey: task.meetingID) }
                continue
            }
            request.children[task.meetingID] = task.id
            if task.state == .completed || task.state == .failed || task.state == .cancelled {
                request.finished += 1
                if task.state == .failed { request.failed += 1 }
                if task.state == .cancelled { request.cancelled += 1 }
            }
        }
        if let meetings = request.meetings, request.finished == meetings.count {
            request.state = .completed
        }
        if request != localSearch.rebuildRequest { try localSearch.saveRebuild(request) }
    }
}
