import Foundation

enum ManagedTaskState: String, Codable, CaseIterable, Sendable {
    case queued, running, completed, failed, cancelled
    var isActive: Bool { self == .queued || self == .running }
}

enum ManagedTaskRecovery: String, Codable, Sendable {
    case automatic, manual, restartRequired, blocked, none
}

struct ManagedTaskRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: BackgroundJob.Kind
    var meetingID: UUID
    var meetingTitle: String
    var providerID: UUID?
    var providerName: String?
    var summaryInstructions: String?
    var searchIndexRevision: String?
    var state: ManagedTaskState = .queued
    var progress = "Waiting to start"
    var errorMessage: String?
    var createdAt = Date()
    var finishedAt: Date?
    var isPreview = false
    var isAutomatic = false
    var interrupted = false
    var recovery: ManagedTaskRecovery = .automatic
    var attemptKey: String?
    var remoteJobID: String?
    var speakerLabelingResultID: UUID?
    var submissionUncertain = false
    var hasSavedResult = false
    var providerFailed = false
    var userStopped = false
    var dismissRequested = false
    var restartRequested = false
    /// Scheduler priority is independent of newest-first presentation.
    var queuePriority: Int64 = 0
    var key: BackgroundJob.Key { .init(kind: kind, scope: .meeting(meetingID)) }
}

struct MissingTranscriptionJob: LocalizedError {
    var errorDescription: String? {
        "The provider no longer has this transcription request. Restart to submit the recording again."
    }
}

extension MeetingStore {
    static let maximumConcurrentTranscriptions = 2
    static let maximumConcurrentSummaries = 1
    static let maximumConcurrentSpeakerLabeling = 1

    var managedTaskCount: Int { managedTaskStateCounts.values.reduce(0, +) + managedTasks.filter(\.isPreview).count }

    func managedTask(id: UUID) -> ManagedTaskRecord? {
        managedTasks.first { $0.id == id }
    }

    func cacheManagedTask(_ task: ManagedTaskRecord) {
        if let index = managedTasks.firstIndex(where: { $0.id == task.id }) {
            managedTasks[index] = task
        }
        else {
            managedTasks.append(task)
        }
        // Running records and synthetic previews are pinned; inactive payloads are a small cache.
        let removable = managedTasks.filter { $0.state != .running && !$0.isPreview }
        if removable.count > 100 {
            let removed = Set(removable.prefix(removable.count - 100).map(\.id))
            managedTasks.removeAll { removed.contains($0.id) }
        }
    }

    var tasksNewestFirst: [ManagedTaskRecord] { managedTasks.sorted(by: ManagedTaskJournal.newestFirst) }

    @discardableResult func queueTranscriptionCommand(id: UUID, providerID: UUID? = nil) async -> UUID? {
        guard await ensureMeetingLoaded(id: id), recordingID != id, !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id })
        else { return nil }
        return await enqueueManagedTask(
            kind: .transcription, meeting: meeting,
            providerID: providerID ?? meeting.transcriptionAttempt?.providerID ?? settings.transcriptionProviderID)
    }

    @discardableResult func queueSummaryCommand(
        id: UUID, providerID: UUID? = nil, automatically: Bool = false, instructions: String? = nil
    ) async -> UUID? {
        guard await ensureMeetingLoaded(id: id), let meeting = meetings.first(where: { $0.id == id }) else {
            return nil
        }
        return await enqueueManagedTask(
            kind: .summary, meeting: meeting, providerID: providerID ?? settings.summaryProviderID,
            automatically: automatically, summaryInstructions: instructions)
    }

    @discardableResult func queueSpeakerLabelingCommand(id: UUID, providerID: UUID? = nil) async -> UUID? {
        let selectedID = providerID ?? settings.diarizationProviderID
        guard libraryWritable, await ensureMeetingLoaded(id: id), recordingID != id,
            !isJobRunning(.transcription, .meeting(id)), !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id }), meeting.transcriptionAttempt == nil,
            settings.serviceProviders.contains(where: {
                $0.id == selectedID && $0.kind == .community1 && $0.supports(.diarization)
            })
        else {
            errorMessage = "Choose Community-1 for Speaker Labeling in Settings before labeling a saved transcript."
            return nil
        }
        return await enqueueManagedTask(kind: .diarization, meeting: meeting, providerID: selectedID)
    }

    @discardableResult func queueSearchIndexCommand(id: UUID, revision: String? = nil, force: Bool = false) async
        -> UUID?
    {
        guard let selected = selectedSearchProvider,
            await ensureMeetingLoaded(id: id), let meeting = meetings.first(where: { $0.id == id })
        else { return nil }
        let source: String
        if let revision {
            source = revision
        }
        else {
            let directory = dataDirectory
            guard
                let fingerprint = try? await Task.detached(
                    priority: .utility,
                    operation: {
                        try SemanticSource.fingerprint(
                            folder: MeetingFolderLocation.resolve(id: id, directory: directory))
                    }
                ).value
            else { return nil }
            source = (selected.localSearch ?? .init()).selectedModel.space + ":" + fingerprint
        }
        return await enqueueManagedTask(
            kind: .searchIndex, meeting: meeting, providerID: selected.id, automatically: true,
            searchIndexRevision: source, retryStopped: force)
    }

    private func enqueueManagedTask(
        kind: BackgroundJob.Kind, meeting: Meeting, providerID: UUID?, automatically: Bool = false,
        summaryInstructions: String? = nil, searchIndexRevision: String? = nil, retryStopped: Bool = false
    ) async -> UUID? {
        let key = BackgroundJob.Key(kind: kind, scope: .meeting(meeting.id))
        guard !isChangingLibrary, !isPreparingToQuit, !managedTasksLoading,
            managedTaskActiveCounts[key, default: 0] == 0,
            !backgroundJobs.contains(where: { $0.key == key })
        else { return nil }
        let journal = managedTaskJournal
        do {
            let existing = try await managedTaskIO.perform {
                try journal.query(
                    where: "meeting=" + ManagedTaskIndex.literal(meeting.id.uuidString)
                        + " AND kind=" + ManagedTaskIndex.literal(kind.rawValue)
                        + " AND state IN ('queued','running')", limit: 1)
            }
            guard existing.isEmpty else { return nil }
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return nil
        }
        // Retry/resume represents the same intent, so it updates the original row.
        // Only an explicitly new request after completion creates another row.
        var task: ManagedTaskRecord
        do {
            task =
                try await previousManagedIntent(kind: kind, meeting: meeting)
                ?? ManagedTaskRecord(kind: kind, meetingID: meeting.id, meetingTitle: meeting.title)
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return nil
        }
        if task.recovery == .restartRequired || task.restartRequested { return nil }
        if kind == .searchIndex {
            if task.userStopped, task.searchIndexRevision == searchIndexRevision, !retryStopped { return nil }
            task.searchIndexRevision = searchIndexRevision
        }
        task.providerID = providerID
        if kind == .summary {
            let instructions = summaryInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            task.summaryInstructions = instructions?.isEmpty == false ? instructions : nil
        }
        task.providerName =
            providerID == ThisMacProvider.id
            ? "This Mac" : settings.serviceProviders.first { $0.id == providerID }?.name
        task.meetingTitle = meeting.title
        task.state = .queued
        task.progress = "Waiting to start"
        task.errorMessage = nil
        task.finishedAt = nil
        task.recovery = .automatic
        task.isAutomatic = automatically
        task.userStopped = false
        task.interrupted = false
        if kind == .diarization { task.speakerLabelingResultID = nil }
        if kind == .transcription, let attempt = meeting.transcriptionAttempt { task.capture(attempt) }
        guard await saveManagedTask(task) else { return nil }
        await startManagedTasks()
        return task.id
    }

    private func previousManagedIntent(kind: BackgroundJob.Kind, meeting: Meeting) async throws -> ManagedTaskRecord? {
        let predicate =
            "meeting=" + ManagedTaskIndex.literal(meeting.id.uuidString) + " AND kind="
            + ManagedTaskIndex.literal(kind.rawValue) + " AND state!='completed'"
        let journal = managedTaskJournal
        return try await managedTaskIO.perform {
            var cursor: ManagedTaskJournal.Cursor?
            while true {
                let page = journal.page(after: cursor, limit: 50, predicate: predicate)
                if let failure = journal.readFailure { throw failure }
                if let existing = page.first(where: {
                    !$0.dismissRequested
                        && (kind != .transcription || $0.attemptKey == meeting.transcriptionAttempt?.idempotencyKey)
                }) {
                    return existing
                }
                guard page.count == 50, let last = page.last else { return nil }
                cursor = .init(createdAt: last.createdAt, id: last.id)
            }
        }
    }

    /// Journal first: provider work must not start from an uncommitted intent.
    @discardableResult private func saveManagedTask(_ task: ManagedTaskRecord) async -> Bool {
        do {
            guard libraryWritable else { throw ServiceError("The meeting library is read-only.") }
            if !task.isPreview {
                let journal = managedTaskJournal
                let previous = try await managedTaskIO.perform {
                    let previous = try journal.query(
                        where: "id=" + ManagedTaskIndex.literal(task.id.uuidString), limit: 1
                    ).first
                    try journal.upsert(task)
                    return previous
                }
                if let previous {
                    managedTaskStateCounts[previous.state, default: 0] -= 1
                    if previous.state.isActive {
                        let remaining = managedTaskActiveCounts[previous.key, default: 0] - 1
                        if remaining > 0 {
                            managedTaskActiveCounts[previous.key] = remaining
                        }
                        else {
                            managedTaskActiveCounts.removeValue(forKey: previous.key)
                        }
                    }
                }
                managedTaskStateCounts[task.state, default: 0] += 1
                if task.state.isActive { managedTaskActiveCounts[task.key, default: 0] += 1 }
            }
            cacheManagedTask(task)
            managedTaskRevision += 1
            if !task.state.isActive && managedTaskOperations[task.id] == nil {
                for waiter in managedTaskWaiters.removeValue(forKey: task.id) ?? [] { waiter.resume() }
            }
            return true
        }
        catch {
            managedTaskJournalError = "Couldn’t save tasks. \(error.localizedDescription)"
            if isPreparingToQuit { managedTaskShutdownError = managedTaskJournalError }
            return false
        }
    }

    private func startManagedTasks() async {
        guard !isChangingLibrary, !isPreparingToQuit, !isSchedulingManagedTasks, !managedTasksLoading else { return }
        isSchedulingManagedTasks = true
        defer { isSchedulingManagedTasks = false }
        for kind in [BackgroundJob.Kind.transcription, .summary, .diarization, .searchIndex] {
            let limit =
                kind == .transcription
                ? Self.maximumConcurrentTranscriptions
                : kind == .searchIndex
                    ? 1 : kind == .diarization ? Self.maximumConcurrentSpeakerLabeling : Self.maximumConcurrentSummaries
            while true {
                let running = managedTasks.filter { $0.kind == kind && $0.state == .running && !$0.isPreview }.count
                guard running < limit else { break }
                let journal = managedTaskJournal
                let candidates: [ManagedTaskRecord]
                do {
                    candidates = try await managedTaskIO.perform {
                        try journal.query(
                            where: "kind=" + ManagedTaskIndex.literal(kind.rawValue) + " AND state='queued'",
                            order: "priority DESC,created,id", limit: limit - running)
                    }
                }
                catch {
                    managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
                    for task in managedTasks where task.state == .queued {
                        failUncommittedTask(task)
                    }
                    return
                }
                guard !isPreparingToQuit else { return }
                guard !candidates.isEmpty else { break }
                for candidate in candidates {
                    let id = candidate.id
                    var task = candidate
                    cacheManagedTask(task)
                    if managedTaskStopRequests.contains(id)
                        || (task.kind == .summary && task.isAutomatic && !settings.autoSummarize)
                    {
                        await cancelManagedTaskCommand(id: id)
                        // A rejected durable transition must not retry the same head forever.
                        guard managedTaskActiveCounts[task.key, default: 0] == 0 else { return }
                        continue
                    }
                    task.state = .running
                    task.progress = "Starting…"
                    guard await saveManagedTask(task) else {
                        failUncommittedTask(task)
                        return
                    }
                    if managedTaskStopRequests.contains(id) {
                        await finishManagedTask(
                            id, state: .cancelled, recovery: .manual, message: "Removed before it started.")
                        continue
                    }
                    if isPreparingToQuit {
                        task.state = .queued
                        task.progress = "Waiting to start"
                        _ = await saveManagedTask(task)
                        return
                    }
                    guard beginJob(task.kind, .meeting(task.meetingID), progress: "Starting…") else {
                        task.state = .queued
                        task.progress = "Waiting to start"
                        _ = await saveManagedTask(task)
                        return
                    }
                    managedTaskOperations[id] = Task { [weak self] in await self?.runManagedTask(id) }
                }
            }
        }
    }

    private func runManagedTask(_ id: UUID) async {
        guard let task = managedTask(id: id) else { return }
        do {
            try Task.checkCancellation()
            guard await ensureMeetingLoaded(id: task.meetingID),
                let meeting = meetings.first(where: { $0.id == task.meetingID })
            else {
                throw ServiceError("This meeting no longer exists.")
            }
            try Task.checkCancellation()
            if meeting.completedTaskIDs[task.kind.rawValue] == task.id {
                await completeManagedTask(id, state: .completed, recovery: .none)
                return
            }
            switch task.kind {
            case .transcription:
                try await performTranscription(id: task.meetingID, providerID: task.providerID)
            case .summary:
                if task.kind == .summary && task.isAutomatic && !settings.autoSummarize {
                    await completeManagedTask(
                        id, state: .cancelled, recovery: .none, message: "Automatically Summarize is turned off.")
                    return
                }
                pendingAutomaticSummaries.remove(task.meetingID)
                try await performSummary(
                    id: task.meetingID, providerID: task.providerID, instructions: task.summaryInstructions)
            case .searchIndex:
                try await performSearchIndex(id: task.meetingID, providerID: task.providerID)
            case .diarization:
                try await performLocalDiarization(id: task.meetingID, providerID: task.providerID)
            default: throw ServiceError("This task type cannot run from Tasks yet.")
            }
            try Task.checkCancellation()
            await completeManagedTask(id, state: .completed, recovery: .none)
            if task.kind == .transcription { scheduleAutomaticSpeakerLabeling(id: task.meetingID) }
            if task.kind == .searchIndex { scheduleSearchIndexing() }
        }
        catch {
            if Task.isCancelled || error is CancellationError {
                if isPreparingToQuit && !managedTaskStopRequests.contains(id) {
                    let hasReceipt =
                        meetings.first(where: { $0.id == task.meetingID })?
                        .completedTaskIDs[task.kind.rawValue] == id
                    await completeManagedTask(
                        id, state: hasReceipt ? .completed : .failed,
                        recovery: hasReceipt ? .none : task.kind == .transcription ? .automatic : .manual,
                        message: hasReceipt ? nil : "Interrupted when the app closed.")
                }
                else {
                    await completeManagedTask(
                        id, state: .cancelled, recovery: .manual,
                        message: task.kind == .searchIndex
                            ? "Search indexing stopped."
                            : task.kind == .diarization
                                ? "Speaker labeling cancelled. The current transcript was kept."
                                : "Stopped waiting on this Mac. The provider may still be processing the request.")
                }
                if task.kind == .searchIndex, !Task.isCancelled, !isPreparingToQuit { scheduleSearchIndexing() }
            }
            else if task.kind == .searchIndex, case SearchProviderError.sourceChanged = error {
                await completeManagedTask(id, state: .cancelled, recovery: .none, message: error.localizedDescription)
                scheduleSearchIndexing()
            }
            else if error is MissingTranscriptionJob {
                await completeManagedTask(
                    id, state: .failed, recovery: .restartRequired, message: error.localizedDescription)
            }
            else {
                let latest = managedTasks.first { $0.id == id } ?? task
                let retryOnWake =
                    latest.kind == .transcription && latest.remoteJobID != nil
                    && !latest.providerFailed && !latest.hasSavedResult
                    && (error is URLError || (error as? ServiceHTTPStatusError).map { $0.statusCode >= 500 } == true)
                await completeManagedTask(
                    id, state: .failed, recovery: retryOnWake ? .automatic : .manual,
                    message: error.localizedDescription)
            }
        }
    }

    private func completeManagedTask(
        _ id: UUID, state: ManagedTaskState, recovery: ManagedTaskRecovery, message: String? = nil
    ) async {
        await managedTaskCommands.run {
            await self.finishManagedTask(id, state: state, recovery: recovery, message: message)
        }
    }

    private func finishManagedTask(
        _ id: UUID, state: ManagedTaskState, recovery: ManagedTaskRecovery, message: String? = nil
    ) async {
        guard var task = managedTask(id: id) else { return }
        task.state = state
        task.recovery = recovery
        task.finishedAt = Date()
        task.errorMessage = message
        task.progress = state == .completed ? "Completed" : state == .cancelled ? "Stopped" : "Needs attention"
        let committed = await saveManagedTask(task)
        if committed {
            managedTaskStopRequests.remove(id)
        }
        else {
            // The result receipt, committed with meeting content, protects recovery.
            if let index = managedTasks.firstIndex(where: { $0.id == id }) { managedTasks[index] = task }
        }
        managedTaskOperations.removeValue(forKey: id)
        endJob(task.kind, .meeting(task.meetingID))
        for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        await reloadExternalManagedTasksCommand()
        await startManagedTasks()
        if task.kind == .summary { startPendingAutomaticSummary(id: task.meetingID) }
    }

    private func failUncommittedTask(_ task: ManagedTaskRecord) {
        if let index = managedTasks.firstIndex(where: { $0.id == task.id }) {
            managedTasks[index].state = .failed
            managedTasks[index].recovery = .manual
            managedTasks[index].errorMessage = managedTaskJournalError
        }
        endJob(task.kind, .meeting(task.meetingID))
        for waiter in managedTaskWaiters.removeValue(forKey: task.id) ?? [] { waiter.resume() }
    }

    func cancelManagedTaskCommand(id: UUID) async {
        guard var task = managedTask(id: id), task.state.isActive else {
            managedTaskStopRequests.remove(id)
            return
        }
        if task.kind == .summary { pendingAutomaticSummaries.remove(task.meetingID) }
        task.userStopped = true
        task.recovery = .manual
        task.progress = "Stopping…"
        guard await saveManagedTask(task) else {
            if task.state == .queued { failUncommittedTask(task) }
            return
        }
        if task.state == .queued || task.isPreview {
            await finishManagedTask(
                id, state: .cancelled, recovery: .manual,
                message: task.state == .queued ? "Removed before it started." : "Stopped waiting on this Mac.")
        }
        else {
            managedTaskOperations[id]?.cancel()
        }
    }

    func canRetryManagedTask(_ task: ManagedTaskRecord) -> Bool {
        guard task.state == .failed || task.state == .cancelled,
            !isJobRunning(task.kind, .meeting(task.meetingID)), !task.dismissRequested, !task.restartRequested,
            task.recovery != .restartRequired && task.recovery != .blocked
        else { return false }
        if task.isPreview || task.kind == .summary { return true }
        if task.kind == .searchIndex { return selectedSearchProvider != nil }
        if task.kind == .diarization {
            return recordingID != task.meetingID && !isJobRunning(.transcription, .meeting(task.meetingID))
                && !isJobRunning(.importAudio, .meeting(task.meetingID))
                && settings.serviceProviders.contains {
                    $0.id == task.providerID && $0.kind == .community1 && $0.supports(.diarization)
                }
        }
        if let current = meetings.first(where: { $0.id == task.meetingID })?.transcriptionAttempt {
            guard current.idempotencyKey == task.attemptKey, current.failure == nil, current.result == nil,
                !current.submissionUncertain || current.taskID != nil
            else { return false }
        }
        return task.kind == .transcription && recordingID != task.meetingID
            && !isJobRunning(.importAudio, .meeting(task.meetingID)) && !task.providerFailed && !task.hasSavedResult
            && (!task.submissionUncertain || task.remoteJobID != nil)
    }

    func canRestartManagedTask(_ task: ManagedTaskRecord) -> Bool {
        task.recovery == .restartRequired && task.kind == .transcription && !task.state.isActive
            && !isJobRunning(.transcription, .meeting(task.meetingID))
    }

    func managedTaskActionTitle(_ task: ManagedTaskRecord) -> String {
        task.kind == .transcription && (task.interrupted || task.attemptKey != nil) ? "Resume" : "Retry"
    }

    func retryManagedTaskCommand(id: UUID) async {
        guard let task = managedTask(id: id), canRetryManagedTask(task) else { return }
        if task.isPreview {
            await finishManagedTask(id, state: .completed, recovery: .none)
            return
        }
        guard await ensureMeetingLoaded(id: task.meetingID), canRetryManagedTask(task) else { return }
        if task.kind == .transcription {
            _ = await queueTranscriptionCommand(id: task.meetingID, providerID: task.providerID)
        }
        else if task.kind == .searchIndex {
            _ = await queueSearchIndexCommand(id: task.meetingID, force: true)
        }
        else if task.kind == .diarization {
            _ = await queueSpeakerLabelingCommand(id: task.meetingID, providerID: task.providerID)
        }
        else {
            _ = await queueSummaryCommand(
                id: task.meetingID, providerID: task.providerID, instructions: task.summaryInstructions)
        }
    }

    func restartManagedTaskCommand(id: UUID) async {
        if let preview = managedTasks.first(where: { $0.id == id && $0.isPreview }), canRestartManagedTask(preview) {
            await finishManagedTask(id, state: .completed, recovery: .none)
            return
        }
        guard var task = managedTask(id: id), canRestartManagedTask(task),
            await ensureMeetingLoaded(id: task.meetingID),
            let meeting = meetings.first(where: { $0.id == task.meetingID }),
            let attempt = meeting.transcriptionAttempt, attempt.idempotencyKey == task.attemptKey,
            attempt.remoteJobExpired == true
        else { return }
        task.restartRequested = true
        guard await saveManagedTask(task) else { return }
        await finishRequestedRestart(task)
    }

    private func finishRequestedRestart(_ original: ManagedTaskRecord) async {
        guard await ensureMeetingLoaded(id: original.meetingID),
            var meeting = meetings.first(where: { $0.id == original.meetingID })
        else { return }
        if let attempt = meeting.transcriptionAttempt {
            guard attempt.idempotencyKey == original.attemptKey && attempt.remoteJobExpired == true else { return }
            meeting.transcriptionAttempt = nil
            guard await updateMeeting(meeting) else { return }
        }
        var task = original
        task.restartRequested = false
        task.attemptKey = nil
        task.remoteJobID = nil
        task.submissionUncertain = false
        task.providerFailed = false
        task.hasSavedResult = false
        task.state = .queued
        task.recovery = .automatic
        task.userStopped = false
        task.errorMessage = nil
        task.finishedAt = nil
        task.progress = "Waiting to restart"
        guard await saveManagedTask(task) else { return }
        await startManagedTasks()
    }

    func prioritizeManagedTaskCommand(id: UUID) async {
        guard var task = managedTask(id: id), task.state == .queued else { return }
        let journal = managedTaskJournal
        do {
            task.queuePriority = try await managedTaskIO.perform {
                (try journal.query(order: "priority DESC", limit: 1).first?.queuePriority ?? 0) + 1
            }
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return
        }
        guard await saveManagedTask(task) else { return }
        await startManagedTasks()
    }

    func removeManagedTaskCommand(id: UUID) async {
        guard var task = managedTask(id: id), task.state != .running else { return }
        if task.state == .queued { await cancelManagedTaskCommand(id: id) }
        guard !isJobRunning(task.kind, .meeting(task.meetingID)) else { return }
        task.state = task.state == .queued ? .cancelled : task.state
        task.dismissRequested = true
        task.userStopped = true
        guard await saveManagedTask(task) else { return }
        await finishRequestedDismiss(task)
    }

    private func finishRequestedDismiss(_ task: ManagedTaskRecord) async {
        if task.kind == .transcription, let attemptKey = task.attemptKey, await ensureMeetingLoaded(id: task.meetingID),
            var meeting = meetings.first(where: { $0.id == task.meetingID }),
            meeting.transcriptionAttempt?.idempotencyKey == attemptKey
        {
            meeting.transcriptionAttempt = nil
            guard await updateMeeting(meeting) else { return }
        }
        do {
            if !task.isPreview {
                let journal = managedTaskJournal
                try await managedTaskIO.perform { try journal.delete(task.id) }
                managedTaskStateCounts[task.state, default: 0] -= 1
            }
            managedTasks.removeAll { $0.id == task.id }
            managedTaskStopRequests.remove(task.id)
            managedTaskRevision += 1
        }
        catch { managedTaskJournalError = "Couldn’t dismiss this task. \(error.localizedDescription)" }
    }

    /// External task edits are displayed after current operations finish. Changed active rows
    /// require a deliberate Resume so editing a file cannot silently submit new provider work.
    func reloadExternalManagedTasksCommand() async {
        guard !isChangingLibrary, !isPreparingToQuit, managedTaskOperations.isEmpty else { return }
        let journal = managedTaskJournal
        do {
            let changed = try await managedTaskIO.perform { journal.hasExternalChanges }
            guard changed else { return }
            let initial = try await managedTaskIO.perform {
                try journal.prepare()
                return try ManagedTaskSnapshot.read(journal)
            }
            applyManagedTaskSnapshot(initial)
            var cursor: ManagedTaskJournal.Cursor?
            while true {
                let nextCursor = cursor
                let (batch, next) = try await managedTaskIO.perform {
                    let records = journal.page(after: nextCursor, limit: 50, predicate: "state IN ('queued','running')")
                    if let failure = journal.readFailure { throw failure }
                    let changed = try records.filter { try $0.state == .running || journal.changedSinceRebuild($0.id) }
                    let next = records.last.map { ManagedTaskJournal.Cursor(createdAt: $0.createdAt, id: $0.id) }
                    return (changed, next)
                }
                guard let next else { break }
                cursor = next
                for var record in batch {
                    if record.state == .running, await ensureMeetingLoaded(id: record.meetingID),
                        let meeting = meetings.first(where: { $0.id == record.meetingID }),
                        meeting.completedTaskIDs[record.kind.rawValue] == record.id
                    {
                        record.state = .completed
                        record.recovery = .none
                        record.progress = "Completed"
                        record.errorMessage = nil
                        record.finishedAt = record.finishedAt ?? Date()
                    }
                    else {
                        record.state = .failed
                        record.recovery = .manual
                        record.progress = "Needs attention"
                        record.errorMessage = "This task changed outside the app. Resume to continue."
                    }
                    guard await saveManagedTask(record) else {
                        throw ServiceError(managedTaskJournalError ?? "Couldn’t save tasks.")
                    }
                }
            }
            applyManagedTaskSnapshot(try await managedTaskIO.perform { try ManagedTaskSnapshot.read(journal) })
            managedTaskJournalError = nil
        }
        catch {
            managedTaskJournalError = "Couldn’t reload tasks. \(error.localizedDescription)"
            libraryDataStatus.error = managedTaskJournalError
        }
    }

    private func applyManagedTaskSnapshot(_ snapshot: ManagedTaskSnapshot) {
        let recentIDs = Set(snapshot.recent.map(\.id))
        let pinned = managedTasks.filter {
            !recentIDs.contains($0.id) && ($0.isPreview || managedTaskOperations[$0.id] != nil)
        }
        managedTasks = snapshot.recent + pinned
        managedTaskStateCounts = snapshot.counts
        managedTaskActiveCounts = snapshot.activeCounts
        for id in Array(managedTaskWaiters.keys)
        where !snapshot.activeIDs.contains(id) && managedTaskOperations[id] == nil {
            for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        }
        managedTaskRevision += 1
    }

    func prepareManagedTasks() async {
        await managedTaskCommands.run {
            self.managedTasksLoading = true
            do {
                try await self.restoreManagedTasksCommand()
                self.managedTasksLoading = false
                await self.recoverUnfinishedManagedTasksCommand()
            }
            catch {
                self.managedTasksLoading = false
                self.managedTaskJournalError = "Couldn’t load tasks. \(error.localizedDescription)"
            }
        }
    }

    func restoreManagedTasksCommand() async throws {
        let journal = managedTaskJournal
        let snapshot = try await managedTaskIO.perform {
            try journal.prepare()
            return try ManagedTaskSnapshot.read(journal)
        }
        applyManagedTaskSnapshot(snapshot)
    }

    /// Launch and wake share this path. Existing local operations are never duplicated.
    func recoverUnfinishedManagedTasksCommand() async {
        guard !isChangingLibrary, !isPreparingToQuit, !isSchedulingManagedTasks, !managedTasksLoading else { return }
        isSchedulingManagedTasks = true
        await recoverManagedTaskBatch(after: nil)
    }

    private func recoverManagedTaskBatch(after cursor: ManagedTaskJournal.Cursor?) async {
        guard !isChangingLibrary else {
            isSchedulingManagedTasks = false
            return
        }
        let journal = managedTaskJournal
        let batch: [ManagedTaskRecord]
        do {
            batch = try await managedTaskIO.perform {
                let records = journal.page(after: cursor, limit: 50, predicate: "state!='completed'")
                if let failure = journal.readFailure { throw failure }
                return records
            }
        }
        catch {
            managedTaskJournalError = "Couldn’t recover tasks. \(error.localizedDescription)"
            isSchedulingManagedTasks = false
            return
        }
        guard let last = batch.last else {
            isSchedulingManagedTasks = false
            await startManagedTasks()
            return
        }
        for original in batch {
            cacheManagedTask(original)
            guard managedTaskOperations[original.id] == nil else { continue }
            if original.dismissRequested {
                await finishRequestedDismiss(original)
                continue
            }
            if original.restartRequested {
                await finishRequestedRestart(original)
                continue
            }
            guard original.state != .completed else { continue }
            guard await ensureMeetingLoaded(id: original.meetingID),
                let meeting = meetings.first(where: { $0.id == original.meetingID })
            else {
                await finishManagedTask(
                    original.id, state: .failed, recovery: .blocked, message: "This meeting no longer exists.")
                continue
            }
            if meeting.completedTaskIDs[original.kind.rawValue] == original.id {
                await finishManagedTask(original.id, state: .completed, recovery: .none)
                continue
            }
            guard original.state.isActive || (original.state == .failed && original.recovery == .automatic) else {
                continue
            }
            guard [.transcription, .summary, .diarization, .searchIndex].contains(original.kind) else {
                await finishManagedTask(
                    original.id, state: .failed, recovery: .blocked,
                    message: "This app cannot run this task type. The saved task has been kept.")
                continue
            }
            var task = original
            task.interrupted = true
            if task.userStopped {
                await finishManagedTask(
                    task.id, state: .cancelled, recovery: .manual, message: "Stopped waiting on this Mac.")
                continue
            }
            if task.kind == .diarization {
                await finishManagedTask(
                    task.id, state: .failed, recovery: .manual,
                    message: "Speaker labeling was interrupted. Retry starts analysis again.")
                continue
            }
            if task.kind == .summary && task.state != .queued {
                await finishManagedTask(
                    task.id, state: .failed, recovery: .manual,
                    message: "The provider may have processed the summary. Retry starts a new request.")
                continue
            }
            if task.kind == .transcription && task.attemptKey != nil && meeting.transcriptionAttempt == nil {
                await finishManagedTask(
                    task.id, state: .failed, recovery: .blocked,
                    message:
                        "The saved transcription request is missing. Dismiss this task before starting another transcription."
                )
                continue
            }
            if task.kind == .transcription, let attempt = meeting.transcriptionAttempt {
                guard task.attemptKey == attempt.idempotencyKey else {
                    await finishManagedTask(
                        task.id, state: .failed, recovery: .blocked,
                        message: "This meeting has a different transcription request. Open the meeting to review it.")
                    continue
                }
                task.capture(attempt)
                if attempt.remoteJobExpired == true {
                    await finishManagedTask(
                        task.id, state: .failed, recovery: .restartRequired,
                        message: MissingTranscriptionJob().localizedDescription)
                    continue
                }
                if attempt.failure != nil || (attempt.submissionUncertain && attempt.taskID == nil) {
                    await finishManagedTask(
                        task.id, state: .failed, recovery: .blocked,
                        message: attempt.failure
                            ?? "The provider may have accepted this request. Check its job history before submitting again."
                    )
                    continue
                }
            }
            task.state = .queued
            task.progress = "Waiting to resume"
            task.errorMessage = nil
            task.finishedAt = nil
            guard await saveManagedTask(task) else { continue }
        }
        if batch.count < 50 {
            isSchedulingManagedTasks = false
            await startManagedTasks()
        }
        else {
            let next = ManagedTaskJournal.Cursor(createdAt: last.createdAt, id: last.id)
            await recoverManagedTaskBatch(after: next)
        }
    }

    func recordManagedTaskProgress(_ key: BackgroundJob.Key, progress: String) {
        guard var task = managedTasks.first(where: { $0.key == key && $0.state.isActive }), task.progress != progress
        else { return }
        task.progress = progress
        // Progress is presentation, not recovery state. The next durable transition
        // captures it; provider intent/checkpoint bindings still synchronize first.
        cacheManagedTask(task)
    }

    /// Persist the binding before a provider can receive any audio or request.
    func bindManagedTranscriptionAttemptCommand(_ attempt: ProviderTranscriptionAttempt, meetingID: UUID) async throws {
        guard
            var task = managedTasks.first(where: {
                $0.kind == .transcription && $0.meetingID == meetingID && $0.state.isActive
            })
        else { return }
        task.capture(attempt)
        guard await saveManagedTask(task) else {
            throw ServiceError(managedTaskJournalError ?? "Couldn’t save the transcription task.")
        }
    }

    func reconcileManagedTaskCompletionCommand(for meeting: Meeting, kind: BackgroundJob.Kind) async {
        guard let id = meeting.completedTaskIDs[kind.rawValue],
            let record = managedTask(id: id), !record.state.isActive, record.state != .completed
        else { return }
        await finishManagedTask(id, state: .completed, recovery: .none)
    }

    func bindSpeakerLabelingResultCommand(_ resultID: UUID, meetingID: UUID) async throws {
        guard
            var task = managedTasks.first(where: {
                $0.kind == .diarization && $0.meetingID == meetingID && $0.state.isActive
            })
        else { return }
        task.speakerLabelingResultID = resultID
        guard await saveManagedTask(task) else {
            throw ServiceError(managedTaskJournalError ?? "Couldn’t save the speaker-labeling task.")
        }
    }

    func markManagedTaskCompletion(on meeting: inout Meeting, kind: BackgroundJob.Kind) {
        if let task = managedTasks.first(where: { $0.kind == kind && $0.meetingID == meeting.id && $0.state.isActive })
        {
            meeting.completedTaskIDs[kind.rawValue] = task.id
        }
        else if kind == .transcription, let attempt = meeting.transcriptionAttempt,
            let task = managedTasks.first(where: {
                $0.kind == kind && $0.meetingID == meeting.id && $0.attemptKey == attempt.idempotencyKey
            })
        {
            meeting.completedTaskIDs[kind.rawValue] = task.id
        }
    }
}

private extension ManagedTaskRecord {
    mutating func capture(_ attempt: ProviderTranscriptionAttempt) {
        attemptKey = attempt.idempotencyKey
        remoteJobID = attempt.taskID
        submissionUncertain = attempt.submissionUncertain
        hasSavedResult = attempt.result != nil
        providerFailed = attempt.failure != nil
    }
}
