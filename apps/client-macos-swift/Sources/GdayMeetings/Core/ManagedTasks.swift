import Foundation

enum ManagedTaskState: String, Codable, CaseIterable {
    case queued, running, completed, failed, cancelled
    var isActive: Bool { self == .queued || self == .running }
}

struct ManagedTaskRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: BackgroundJob.Kind
    var meetingID: UUID
    var meetingTitle: String
    var providerID: UUID?
    var providerName: String?
    var state: ManagedTaskState = .queued
    var progress = "Waiting to start"
    var errorMessage: String?
    var createdAt = Date()
    var finishedAt: Date?
    /// Synthetic rows never submit provider work from Preview actions.
    var isPreview = false
    var isAutomatic = false
    var interrupted = false
    var key: BackgroundJob.Key { .init(kind: kind, scope: .meeting(meetingID)) }
}

extension MeetingStore {
    /// Separate limits prevent slow remote transcription from blocking summaries.
    static let maximumConcurrentTranscriptions = 2
    static let maximumConcurrentSummaries = 1

    @discardableResult func queueTranscription(id: UUID, providerID: UUID? = nil) -> UUID? {
        guard recordingID != id, !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id })
        else { return nil }
        return enqueueManagedTask(
            kind: .transcription, meeting: meeting,
            providerID: providerID ?? meeting.transcriptionAttempt?.providerID ?? settings.transcriptionProviderID)
    }

    @discardableResult func queueSummary(id: UUID, providerID: UUID? = nil, automatically: Bool = false) -> UUID? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        return enqueueManagedTask(
            kind: .summary, meeting: meeting, providerID: providerID ?? settings.summaryProviderID,
            automatically: automatically)
    }

    private func enqueueManagedTask(
        kind: BackgroundJob.Kind, meeting: Meeting, providerID: UUID?, automatically: Bool = false
    ) -> UUID? {
        guard beginJob(kind, .meeting(meeting.id), progress: "Queued") else { return nil }
        let task = ManagedTaskRecord(
            kind: kind, meetingID: meeting.id, meetingTitle: meeting.title, providerID: providerID,
            providerName: settings.serviceProviders.first { $0.id == providerID }?.name, isAutomatic: automatically)
        managedTasks.append(task)
        do { try persistManagedTasks() }
        catch {
            finishManagedTask(
                task.id, state: .failed, message: "Couldn’t save this task. \(error.localizedDescription)")
            return task.id
        }
        startManagedTasks()
        return task.id
    }

    func waitForManagedTask(_ id: UUID) async {
        guard managedTasks.contains(where: { $0.id == id && $0.state.isActive }) else { return }
        await withCheckedContinuation { continuation in
            managedTaskWaiters[id, default: []].append(continuation)
        }
    }

    private func startManagedTasks() {
        guard !isSchedulingManagedTasks else { return }
        isSchedulingManagedTasks = true
        defer { isSchedulingManagedTasks = false }
        for kind in [BackgroundJob.Kind.transcription, .summary] {
            let limit = kind == .transcription ? Self.maximumConcurrentTranscriptions : Self.maximumConcurrentSummaries
            var available =
                limit - managedTasks.filter { $0.kind == kind && $0.state == .running && !$0.isPreview }.count
            for index in managedTasks.indices where available > 0 {
                guard managedTasks[index].kind == kind, managedTasks[index].state == .queued,
                    !managedTasks[index].isPreview
                else { continue }
                let id = managedTasks[index].id
                if managedTasks[index].isAutomatic && !settings.autoSummarize {
                    cancelManagedTask(id: id)
                    continue
                }
                managedTasks[index].state = .running
                managedTasks[index].progress = "Starting…"
                available -= 1
                do { try persistManagedTasks() }
                catch {
                    finishManagedTask(
                        id, state: .failed, message: "Couldn’t save this task. \(error.localizedDescription)")
                    available += 1
                    continue
                }
                managedTaskOperations[id] = Task { [weak self] in
                    guard let self else { return }
                    await self.runManagedTask(id)
                }
            }
        }
    }

    private func runManagedTask(_ id: UUID) async {
        guard let task = managedTasks.first(where: { $0.id == id }) else { return }
        var state = ManagedTaskState.completed
        var message: String?
        do {
            try Task.checkCancellation()
            switch task.kind {
            case .transcription:
                try await performTranscription(id: task.meetingID, providerID: task.providerID)
            case .summary:
                if task.isAutomatic && !settings.autoSummarize {
                    finishManagedTask(id, state: .cancelled, message: "Automatically Summarize is turned off.")
                    return
                }
                pendingAutomaticSummaries.remove(task.meetingID)
                try await performSummary(id: task.meetingID, providerID: task.providerID)
            default: break
            }
            try Task.checkCancellation()
        }
        catch {
            if Task.isCancelled || error is CancellationError {
                state = .cancelled
                message = "Stopped waiting on this Mac. The provider may still be processing the request."
            }
            else {
                state = .failed
                message = error.localizedDescription
            }
        }
        finishManagedTask(id, state: state, message: message)
    }

    private func finishManagedTask(_ id: UUID, state: ManagedTaskState, message: String?) {
        guard let index = managedTasks.firstIndex(where: { $0.id == id }) else { return }
        let task = managedTasks[index]
        managedTasks[index].state = state
        managedTasks[index].finishedAt = Date()
        managedTasks[index].errorMessage = message
        managedTasks[index].progress =
            state == .completed ? "Completed" : state == .cancelled ? "Stopped" : "Needs attention"
        managedTaskOperations.removeValue(forKey: id)
        do { try persistManagedTasks() }
        catch {
            managedTasks[index].errorMessage =
                (message.map { $0 + " " } ?? "") + "Couldn’t save task history. \(error.localizedDescription)"
        }
        endJob(task.kind, .meeting(task.meetingID))
        for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        startManagedTasks()
        if task.kind == .summary { startPendingAutomaticSummary(id: task.meetingID) }
    }

    func cancelManagedTask(id: UUID) {
        guard let index = managedTasks.firstIndex(where: { $0.id == id }), managedTasks[index].state.isActive else {
            return
        }
        let task = managedTasks[index]
        if task.kind == .summary { pendingAutomaticSummaries.remove(task.meetingID) }
        if task.state == .queued || task.isPreview {
            finishManagedTask(
                id, state: .cancelled,
                message: task.state == .queued
                    ? "Removed before it started."
                    : "Stopped waiting on this Mac. The provider may still be processing the request.")
        }
        else {
            managedTasks[index].progress = "Stopping…"
            managedTaskOperations[id]?.cancel()
        }
    }

    func canRetryManagedTask(_ task: ManagedTaskRecord) -> Bool {
        guard task.state == .failed || task.state == .cancelled,
            !isJobRunning(task.kind, .meeting(task.meetingID)),
            let meeting = meetings.first(where: { $0.id == task.meetingID })
        else { return false }
        if task.isPreview { return true }
        if task.kind == .summary { return true }
        guard task.kind == .transcription, recordingID != task.meetingID,
            !isJobRunning(.importAudio, .meeting(task.meetingID))
        else { return false }
        if let attempt = meeting.transcriptionAttempt {
            return attempt.failure == nil && attempt.result == nil
                && (!attempt.submissionUncertain || attempt.taskID != nil)
        }
        return true
    }

    func managedTaskActionTitle(_ task: ManagedTaskRecord) -> String {
        task.kind == .transcription
            && (task.interrupted || meetings.first(where: { $0.id == task.meetingID })?.transcriptionAttempt != nil)
            ? "Resume" : "Retry"
    }

    func retryManagedTask(id: UUID) {
        guard let index = managedTasks.firstIndex(where: { $0.id == id }), canRetryManagedTask(managedTasks[index])
        else { return }
        let task = managedTasks[index]
        if task.isPreview {
            managedTasks[index].state = .completed
            managedTasks[index].progress = "Completed in Preview"
            managedTasks[index].errorMessage = nil
            managedTasks[index].finishedAt = Date()
        }
        else {
            let replacement =
                task.kind == .transcription
                ? queueTranscription(id: task.meetingID, providerID: task.providerID)
                : queueSummary(id: task.meetingID, providerID: task.providerID)
            if replacement != nil { removeManagedTask(id: id) }
        }
    }

    func prioritizeManagedTask(id: UUID) {
        guard let index = managedTasks.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        let task = managedTasks.remove(at: index)
        let firstQueued =
            managedTasks.firstIndex { $0.state == .queued && $0.kind == task.kind } ?? managedTasks.endIndex
        managedTasks.insert(task, at: firstQueued)
        do { try persistManagedTasks() }
        catch {
            if let index = managedTasks.firstIndex(where: { $0.id == id }) {
                managedTasks[index].errorMessage = "Couldn’t save the task order. \(error.localizedDescription)"
            }
        }
        startManagedTasks()
    }

    func removeManagedTask(id: UUID) {
        guard let task = managedTasks.first(where: { $0.id == id }) else { return }
        if task.state == .queued { cancelManagedTask(id: id) }
        guard managedTasks.first(where: { $0.id == id })?.state.isActive == false else { return }
        let previous = managedTasks
        managedTasks.removeAll { $0.id == id }
        do { try persistManagedTasks() }
        catch { managedTasks = previous }
    }

    private func persistManagedTasks() throws {
        guard libraryWritable else { throw ServiceError("The meeting library is read-only.") }
        let records = managedTasks.filter { !$0.isPreview }
        let data = try JSONEncoder().encode(records)
        let url = dataDirectory.appendingPathComponent("managed-tasks.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func restoreManagedTasks() throws {
        let url = dataDirectory.appendingPathComponent("managed-tasks.json")
        if FileManager.default.fileExists(atPath: url.path) {
            managedTasks = try JSONDecoder().decode([ManagedTaskRecord].self, from: Data(contentsOf: url))
            for index in managedTasks.indices where managedTasks[index].state.isActive {
                let queued = managedTasks[index].state == .queued
                managedTasks[index].state = .failed
                managedTasks[index].interrupted = true
                managedTasks[index].progress = "Paused"
                managedTasks[index].errorMessage =
                    queued
                    ? "This task was queued when the app closed. Resume it to start."
                    : managedTasks[index].kind == .summary
                        ? "The provider may have processed the previous summary request. Retry starts another request."
                        : "Stopped waiting when the app closed. Resume to check the saved transcription request."
            }
        }
    }
}
