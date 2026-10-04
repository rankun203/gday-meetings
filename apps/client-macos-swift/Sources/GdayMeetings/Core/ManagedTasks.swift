import Foundation

enum ManagedTaskState: String, Codable, CaseIterable {
    case queued, running, completed, failed, cancelled
    var isActive: Bool { self == .queued || self == .running }
}

enum ManagedTaskRecovery: String, Codable {
    case automatic, manual, restartRequired, blocked, none
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

    var tasksNewestFirst: [ManagedTaskRecord] { managedTasks.sorted(by: ManagedTaskJournal.newestFirst) }

    @discardableResult func queueTranscription(id: UUID, providerID: UUID? = nil) -> UUID? {
        guard ensureMeetingLoaded(id: id), recordingID != id, !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id })
        else { return nil }
        return enqueueManagedTask(
            kind: .transcription, meeting: meeting,
            providerID: providerID ?? meeting.transcriptionAttempt?.providerID ?? settings.transcriptionProviderID)
    }

    @discardableResult func queueSummary(id: UUID, providerID: UUID? = nil, automatically: Bool = false) -> UUID? {
        guard ensureMeetingLoaded(id: id), let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        return enqueueManagedTask(
            kind: .summary, meeting: meeting, providerID: providerID ?? settings.summaryProviderID,
            automatically: automatically)
    }

    @discardableResult func queueSpeakerLabeling(id: UUID, providerID: UUID? = nil) -> UUID? {
        let selectedID = providerID ?? settings.diarizationProviderID
        guard libraryWritable, ensureMeetingLoaded(id: id), recordingID != id,
            !isJobRunning(.transcription, .meeting(id)), !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id }), meeting.transcriptionAttempt == nil,
            settings.serviceProviders.contains(where: {
                $0.id == selectedID && $0.kind == .community1 && $0.supports(.diarization)
            })
        else {
            errorMessage = "Choose Community-1 for Speaker Labeling in Settings before labeling a saved transcript."
            return nil
        }
        return enqueueManagedTask(kind: .diarization, meeting: meeting, providerID: selectedID)
    }

    private func enqueueManagedTask(
        kind: BackgroundJob.Kind, meeting: Meeting, providerID: UUID?, automatically: Bool = false
    ) -> UUID? {
        guard !isChangingLibrary, !isJobRunning(kind, .meeting(meeting.id)) else { return nil }
        // Retry/resume represents the same intent, so it updates the original row.
        // Only an explicitly new request after completion creates another row.
        var task =
            managedTasks.last(where: {
                $0.kind == kind && $0.meetingID == meeting.id && $0.state != .completed
                    && !$0.dismissRequested
                    && (kind != .transcription || $0.attemptKey == meeting.transcriptionAttempt?.idempotencyKey)
            }) ?? ManagedTaskRecord(kind: kind, meetingID: meeting.id, meetingTitle: meeting.title)
        if task.recovery == .restartRequired || task.restartRequested { return nil }
        task.providerID = providerID
        task.providerName = settings.serviceProviders.first { $0.id == providerID }?.name
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
        guard saveManagedTask(task) else { return nil }
        guard beginJob(kind, .meeting(meeting.id), progress: "Queued") else { return nil }
        startManagedTasks()
        return task.id
    }

    /// Journal first: provider work must not start from an uncommitted intent.
    @discardableResult private func saveManagedTask(_ task: ManagedTaskRecord) -> Bool {
        do {
            guard libraryWritable else { throw ServiceError("The meeting library is read-only.") }
            if !task.isPreview { try managedTaskJournal.upsert(task) }
            if let index = managedTasks.firstIndex(where: { $0.id == task.id }) {
                managedTasks[index] = task
            }
            else {
                managedTasks.append(task)
            }
            return true
        }
        catch {
            managedTaskJournalError = "Couldn’t save tasks. \(error.localizedDescription)"
            return false
        }
    }

    func waitForManagedTask(_ id: UUID) async {
        guard managedTasks.contains(where: { $0.id == id && $0.state.isActive }) else { return }
        await withCheckedContinuation { managedTaskWaiters[id, default: []].append($0) }
    }

    private func startManagedTasks() {
        guard !isChangingLibrary, !isSchedulingManagedTasks else { return }
        isSchedulingManagedTasks = true
        defer { isSchedulingManagedTasks = false }
        for kind in [BackgroundJob.Kind.transcription, .summary, .diarization] {
            let limit =
                kind == .transcription
                ? Self.maximumConcurrentTranscriptions
                : kind == .diarization ? Self.maximumConcurrentSpeakerLabeling : Self.maximumConcurrentSummaries
            let candidates = managedTasks.filter { $0.kind == kind && $0.state == .queued && !$0.isPreview }
                .sorted {
                    $0.queuePriority == $1.queuePriority
                        ? $0.createdAt < $1.createdAt : $0.queuePriority > $1.queuePriority
                }.map(\.id)
            for id in candidates {
                guard managedTasks.filter({ $0.kind == kind && $0.state == .running && !$0.isPreview }).count < limit,
                    var task = managedTasks.first(where: { $0.id == id && $0.state == .queued })
                else { continue }
                if task.kind == .summary && task.isAutomatic && !settings.autoSummarize {
                    cancelManagedTask(id: id)
                    continue
                }
                task.state = .running
                task.progress = "Starting…"
                guard saveManagedTask(task) else {
                    failUncommittedTask(task)
                    continue
                }
                managedTaskOperations[id] = Task { [weak self] in await self?.runManagedTask(id) }
            }
        }
    }

    private func runManagedTask(_ id: UUID) async {
        guard let task = managedTasks.first(where: { $0.id == id }) else { return }
        do {
            try Task.checkCancellation()
            guard ensureMeetingLoaded(id: task.meetingID),
                let meeting = meetings.first(where: { $0.id == task.meetingID })
            else {
                throw ServiceError("This meeting no longer exists.")
            }
            if meeting.completedTaskIDs[task.kind.rawValue] == task.id {
                finishManagedTask(id, state: .completed, recovery: .none)
                return
            }
            switch task.kind {
            case .transcription:
                try await performTranscription(id: task.meetingID, providerID: task.providerID)
            case .summary:
                if task.kind == .summary && task.isAutomatic && !settings.autoSummarize {
                    finishManagedTask(
                        id, state: .cancelled, recovery: .none, message: "Automatically Summarize is turned off.")
                    return
                }
                pendingAutomaticSummaries.remove(task.meetingID)
                try await performSummary(id: task.meetingID, providerID: task.providerID)
            case .diarization:
                try await performLocalDiarization(id: task.meetingID, providerID: task.providerID)
            default: throw ServiceError("This task type cannot run from Tasks yet.")
            }
            try Task.checkCancellation()
            finishManagedTask(id, state: .completed, recovery: .none)
            if task.kind == .transcription { scheduleAutomaticSpeakerLabeling(id: task.meetingID) }
        }
        catch {
            if Task.isCancelled || error is CancellationError {
                finishManagedTask(
                    id, state: .cancelled, recovery: .manual,
                    message: task.kind == .diarization
                        ? "Speaker labeling cancelled. The current transcript was kept."
                        : "Stopped waiting on this Mac. The provider may still be processing the request.")
            }
            else if error is MissingTranscriptionJob {
                finishManagedTask(id, state: .failed, recovery: .restartRequired, message: error.localizedDescription)
            }
            else {
                let latest = managedTasks.first { $0.id == id } ?? task
                let retryOnWake =
                    latest.kind == .transcription && latest.remoteJobID != nil
                    && !latest.providerFailed && !latest.hasSavedResult
                    && (error is URLError || (error as? ServiceHTTPStatusError).map { $0.statusCode >= 500 } == true)
                finishManagedTask(
                    id, state: .failed, recovery: retryOnWake ? .automatic : .manual,
                    message: error.localizedDescription)
            }
        }
    }

    private func finishManagedTask(
        _ id: UUID, state: ManagedTaskState, recovery: ManagedTaskRecovery, message: String? = nil
    ) {
        guard var task = managedTasks.first(where: { $0.id == id }) else { return }
        task.state = state
        task.recovery = recovery
        task.finishedAt = Date()
        task.errorMessage = message
        task.progress = state == .completed ? "Completed" : state == .cancelled ? "Stopped" : "Needs attention"
        if !saveManagedTask(task) {
            // The result receipt, committed with meeting content, protects recovery.
            if let index = managedTasks.firstIndex(where: { $0.id == id }) { managedTasks[index] = task }
        }
        managedTaskOperations.removeValue(forKey: id)
        endJob(task.kind, .meeting(task.meetingID))
        for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        reloadExternalManagedTasks()
        startManagedTasks()
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

    func cancelManagedTask(id: UUID) {
        guard var task = managedTasks.first(where: { $0.id == id && $0.state.isActive }) else { return }
        if task.kind == .summary { pendingAutomaticSummaries.remove(task.meetingID) }
        task.userStopped = true
        task.recovery = .manual
        task.progress = "Stopping…"
        guard saveManagedTask(task) else { return }
        if task.state == .queued || task.isPreview {
            finishManagedTask(
                id, state: .cancelled, recovery: .manual,
                message: task.state == .queued ? "Removed before it started." : "Stopped waiting on this Mac.")
        }
        else {
            managedTaskOperations[id]?.cancel()
        }
    }

    func canRetryManagedTask(_ task: ManagedTaskRecord) -> Bool {
        guard task.state == .failed || task.state == .cancelled, containsMeeting(id: task.meetingID),
            !isJobRunning(task.kind, .meeting(task.meetingID)), !task.dismissRequested, !task.restartRequested,
            task.recovery != .restartRequired && task.recovery != .blocked
        else { return false }
        if task.isPreview || task.kind == .summary { return true }
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
            && containsMeeting(id: task.meetingID) && !isJobRunning(.transcription, .meeting(task.meetingID))
    }

    func managedTaskActionTitle(_ task: ManagedTaskRecord) -> String {
        task.kind == .transcription && (task.interrupted || task.attemptKey != nil) ? "Resume" : "Retry"
    }

    func retryManagedTask(id: UUID) {
        guard let task = managedTasks.first(where: { $0.id == id }), canRetryManagedTask(task) else { return }
        if task.isPreview {
            finishManagedTask(id, state: .completed, recovery: .none)
            return
        }
        guard ensureMeetingLoaded(id: task.meetingID), canRetryManagedTask(task) else { return }
        if task.kind == .transcription {
            _ = queueTranscription(id: task.meetingID, providerID: task.providerID)
        }
        else if task.kind == .diarization {
            _ = queueSpeakerLabeling(id: task.meetingID, providerID: task.providerID)
        }
        else {
            _ = queueSummary(id: task.meetingID, providerID: task.providerID)
        }
    }

    func restartManagedTask(id: UUID) {
        if let preview = managedTasks.first(where: { $0.id == id && $0.isPreview }), canRestartManagedTask(preview) {
            finishManagedTask(id, state: .completed, recovery: .none)
            return
        }
        guard var task = managedTasks.first(where: { $0.id == id }), canRestartManagedTask(task),
            ensureMeetingLoaded(id: task.meetingID), let meeting = meetings.first(where: { $0.id == task.meetingID }),
            let attempt = meeting.transcriptionAttempt, attempt.idempotencyKey == task.attemptKey,
            attempt.remoteJobExpired == true
        else { return }
        task.restartRequested = true
        guard saveManagedTask(task) else { return }
        finishRequestedRestart(task)
    }

    private func finishRequestedRestart(_ original: ManagedTaskRecord) {
        guard ensureMeetingLoaded(id: original.meetingID),
            var meeting = meetings.first(where: { $0.id == original.meetingID })
        else { return }
        if let attempt = meeting.transcriptionAttempt {
            guard attempt.idempotencyKey == original.attemptKey && attempt.remoteJobExpired == true else { return }
            meeting.transcriptionAttempt = nil
            guard updateMeeting(meeting) else { return }
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
        guard saveManagedTask(task), beginJob(.transcription, .meeting(task.meetingID), progress: "Queued") else {
            return
        }
        startManagedTasks()
    }

    func prioritizeManagedTask(id: UUID) {
        guard var task = managedTasks.first(where: { $0.id == id && $0.state == .queued }) else { return }
        task.queuePriority = (managedTasks.map(\.queuePriority).max() ?? 0) + 1
        guard saveManagedTask(task) else { return }
        startManagedTasks()
    }

    func removeManagedTask(id: UUID) {
        guard var task = managedTasks.first(where: { $0.id == id }), task.state != .running else { return }
        if task.state == .queued { cancelManagedTask(id: id) }
        guard !isJobRunning(task.kind, .meeting(task.meetingID)) else { return }
        task.state = task.state == .queued ? .cancelled : task.state
        task.dismissRequested = true
        task.userStopped = true
        guard saveManagedTask(task) else { return }
        finishRequestedDismiss(task)
    }

    private func finishRequestedDismiss(_ task: ManagedTaskRecord) {
        if task.kind == .transcription, let attemptKey = task.attemptKey, ensureMeetingLoaded(id: task.meetingID),
            var meeting = meetings.first(where: { $0.id == task.meetingID }),
            meeting.transcriptionAttempt?.idempotencyKey == attemptKey
        {
            meeting.transcriptionAttempt = nil
            guard updateMeeting(meeting) else { return }
        }
        do {
            if !task.isPreview { try managedTaskJournal.delete(task.id) }
            managedTasks.removeAll { $0.id == task.id }
        }
        catch { managedTaskJournalError = "Couldn’t dismiss this task. \(error.localizedDescription)" }
    }

    /// External task edits are displayed after current operations finish. Changed active rows
    /// require a deliberate Resume so editing a file cannot silently submit new provider work.
    func reloadExternalManagedTasks() {
        guard !isChangingLibrary, managedTaskOperations.isEmpty, managedTaskJournal.hasExternalChanges else { return }
        do {
            let previous = Dictionary(uniqueKeysWithValues: managedTasks.map { ($0.id, $0) })
            var loaded = try managedTaskJournal.load()
            for index in loaded.indices
            where loaded[index].state.isActive && loaded[index] != previous[loaded[index].id] {
                loaded[index].state = .failed
                loaded[index].recovery = .manual
                loaded[index].progress = "Needs attention"
                loaded[index].errorMessage = "This task changed outside the app. Resume to continue."
                try managedTaskJournal.upsert(loaded[index])
            }
            managedTasks = loaded + managedTasks.filter(\.isPreview)
            managedTaskJournalError = nil
        }
        catch {
            managedTaskJournalError = "Couldn’t reload tasks. \(error.localizedDescription)"
            libraryDataStatus.error = managedTaskJournalError
        }
    }

    func restoreManagedTasks() throws {
        managedTasks = try managedTaskJournal.load()
    }

    /// Launch and wake share this path. Existing local operations are never duplicated.
    func recoverUnfinishedManagedTasks() {
        guard !isChangingLibrary, !isSchedulingManagedTasks else { return }
        isSchedulingManagedTasks = true
        defer {
            isSchedulingManagedTasks = false
            startManagedTasks()
        }
        for original in managedTasks where !original.isPreview {
            guard managedTaskOperations[original.id] == nil else { continue }
            if original.dismissRequested {
                finishRequestedDismiss(original)
                continue
            }
            if original.restartRequested {
                finishRequestedRestart(original)
                continue
            }
            guard original.state != .completed else { continue }
            guard ensureMeetingLoaded(id: original.meetingID),
                let meeting = meetings.first(where: { $0.id == original.meetingID })
            else {
                finishManagedTask(
                    original.id, state: .failed, recovery: .blocked, message: "This meeting no longer exists.")
                continue
            }
            if meeting.completedTaskIDs[original.kind.rawValue] == original.id {
                finishManagedTask(original.id, state: .completed, recovery: .none)
                continue
            }
            guard original.state.isActive || (original.state == .failed && original.recovery == .automatic) else {
                continue
            }
            guard [.transcription, .summary, .diarization].contains(original.kind) else {
                finishManagedTask(
                    original.id, state: .failed, recovery: .blocked,
                    message: "This app cannot run this task type. The saved task has been kept.")
                continue
            }
            var task = original
            task.interrupted = true
            if task.userStopped {
                finishManagedTask(
                    task.id, state: .cancelled, recovery: .manual, message: "Stopped waiting on this Mac.")
                continue
            }
            if task.kind == .diarization {
                finishManagedTask(
                    task.id, state: .failed, recovery: .manual,
                    message: "Speaker labeling was interrupted. Retry starts analysis again.")
                continue
            }
            if task.kind == .summary && task.state != .queued {
                finishManagedTask(
                    task.id, state: .failed, recovery: .manual,
                    message: "The provider may have processed the summary. Retry starts a new request.")
                continue
            }
            if task.kind == .transcription && task.attemptKey != nil && meeting.transcriptionAttempt == nil {
                finishManagedTask(
                    task.id, state: .failed, recovery: .blocked,
                    message:
                        "The saved transcription request is missing. Dismiss this task before starting another transcription."
                )
                continue
            }
            if task.kind == .transcription, let attempt = meeting.transcriptionAttempt {
                guard task.attemptKey == attempt.idempotencyKey else {
                    finishManagedTask(
                        task.id, state: .failed, recovery: .blocked,
                        message: "This meeting has a different transcription request. Open the meeting to review it.")
                    continue
                }
                task.capture(attempt)
                if attempt.remoteJobExpired == true {
                    finishManagedTask(
                        task.id, state: .failed, recovery: .restartRequired,
                        message: MissingTranscriptionJob().localizedDescription)
                    continue
                }
                if attempt.failure != nil || (attempt.submissionUncertain && attempt.taskID == nil) {
                    finishManagedTask(
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
            guard saveManagedTask(task) else { continue }
            _ = beginJob(task.kind, .meeting(task.meetingID), progress: "Queued")
        }
    }

    func recordManagedTaskProgress(_ key: BackgroundJob.Key, progress: String) {
        guard var task = managedTasks.first(where: { $0.key == key && $0.state.isActive }), task.progress != progress
        else { return }
        task.progress = progress
        _ = saveManagedTask(task)
    }

    /// Persist the binding before a provider can receive any audio or request.
    func bindManagedTranscriptionAttempt(_ attempt: ProviderTranscriptionAttempt, meetingID: UUID) throws {
        guard
            var task = managedTasks.first(where: {
                $0.kind == .transcription && $0.meetingID == meetingID && $0.state.isActive
            })
        else { return }
        task.capture(attempt)
        guard saveManagedTask(task) else {
            throw ServiceError(managedTaskJournalError ?? "Couldn’t save the transcription task.")
        }
    }

    func reconcileManagedTaskCompletion(for meeting: Meeting, kind: BackgroundJob.Kind) {
        guard let id = meeting.completedTaskIDs[kind.rawValue],
            managedTasks.contains(where: { $0.id == id && !$0.state.isActive && $0.state != .completed })
        else { return }
        finishManagedTask(id, state: .completed, recovery: .none)
    }

    func bindSpeakerLabelingResult(_ resultID: UUID, meetingID: UUID) throws {
        guard
            var task = managedTasks.first(where: {
                $0.kind == .diarization && $0.meetingID == meetingID && $0.state.isActive
            })
        else { return }
        task.speakerLabelingResultID = resultID
        guard saveManagedTask(task) else {
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
