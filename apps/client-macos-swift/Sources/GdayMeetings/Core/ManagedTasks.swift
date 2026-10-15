import CryptoKit
import Foundation

enum ManagedTaskState: String, Codable, CaseIterable, Sendable {
    case queued, running, paused, completed, failed, cancelled
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
    /// Committed input identity for automatic downstream admission.
    var sourceRevision: String?
    var pipelineID: UUID?
    var dependencyIDs: [UUID]?
    var pipelineOutcome: RecordingPipelineOutcome?
    var extractTodosAfterSummary: Bool?
    var preferFinalizedLiveTranscript: Bool?
    var batchID: UUID?
    var state: ManagedTaskState = .queued
    var progress = "Waiting to start"
    var progressDetails: TaskProgress?
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
    var attentionAcknowledged: Bool?
    var timeline: [TaskAttemptEvent]?
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
            automatically: automatically, summaryInstructions: instructions,
            sourceRevision: Self.automaticTaskSource(meeting, kind: .summary))
    }

    @discardableResult func queueSpeakerLabelingCommand(
        id: UUID, providerID: UUID? = nil, automatically: Bool = false
    ) async -> UUID? {
        let selectedID = (providerID ?? settings.diarizationProviderID)
        guard libraryWritable, await ensureMeetingLoaded(id: id), recordingID != id,
            !isJobRunning(.transcription, .meeting(id)), !isJobRunning(.importAudio, .meeting(id)),
            let meeting = meetings.first(where: { $0.id == id }), meeting.transcriptionAttempt == nil,
            settings.serviceProviders.contains(where: {
                $0.id == selectedID && $0.kind == .speakerLabeling && $0.supports(.diarization)
            })
        else {
            errorMessage = "Choose the Speaker Diarization provider in Settings before diarizing a saved transcript."
            return nil
        }
        return await enqueueManagedTask(
            kind: .diarization, meeting: meeting, providerID: selectedID, automatically: automatically,
            sourceRevision: Self.automaticTaskSource(meeting, kind: .diarization))
    }

    @discardableResult func queueSearchIndexCommand(
        id: UUID, revision: String? = nil, force: Bool = false, batchID: UUID? = nil
    ) async
        -> UUID?
    {
        guard !notesStorage.isEditing(id), batchID.map(isSearchRebuildActive) ?? true else { return nil }
        if recordingID != nil || isStartingRecording || isFinalizingRecording {
            localSearch.deferredRecordingChanges = true
            guard force else { return nil }
        }
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
            kind: .searchIndex, meeting: meeting, providerID: selected.id, automatically: !force,
            searchIndexRevision: source, retryStopped: force, batchID: batchID)
    }

    private func enqueueManagedTask(
        kind: BackgroundJob.Kind, meeting: Meeting, providerID: UUID?, automatically: Bool = false,
        summaryInstructions: String? = nil, sourceRevision: String? = nil,
        searchIndexRevision: String? = nil, retryStopped: Bool = false, batchID: UUID? = nil
    ) async -> UUID? {
        let key = BackgroundJob.Key(kind: kind, scope: .meeting(meeting.id))
        guard batchID.map(isSearchRebuildActive) ?? true,
            kind != .searchIndex || !notesStorage.isEditing(meeting.id)
        else { return nil }
        guard !isChangingLibrary, !isPreparingToQuit, !managedTasksLoading else { return nil }
        if kind == .searchIndex,
            let active = managedTasks.first(where: { $0.key == key && $0.state.isActive })
        {
            // A stopped operation must release its key before another rebuild can
            // adopt the revision; otherwise its completion cancels the new batch.
            guard !active.userStopped, !managedTaskStopRequests.contains(active.id),
                managedTaskOperations[active.id]?.isCancelled != true
            else { return nil }
            if active.searchIndexRevision == searchIndexRevision {
                if let batchID, active.batchID != batchID {
                    var joined = active
                    joined.batchID = batchID
                    joined.isAutomatic = false
                    guard await saveManagedTask(joined) else { return nil }
                }
                return active.id
            }
            // Finish cancellation before a replacement can use the same background-job key.
            // Completion requests a fresh scan, which admits the newest saved source.
            await cancelManagedTaskCommand(id: active.id, userInitiated: false)
            scheduleSearchIndexing()
            return nil
        }
        if automatically, let sourceRevision {
            do {
                if let existing = try await automaticTaskForSource(
                    kind: kind, meetingID: meeting.id, revision: sourceRevision)
                {
                    return existing.id
                }
            }
            catch {
                managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
                return nil
            }
        }
        guard
            kind == .summary
                || (managedTaskActiveCounts[key, default: 0] == 0
                    && !backgroundJobs.contains(where: { $0.key == key }))
        else { return nil }
        let journal = managedTaskJournal
        do {
            let existing = try await managedTaskIO.perform {
                try journal.query(
                    where: "meeting=" + ManagedTaskIndex.literal(meeting.id.uuidString)
                        + " AND kind=" + ManagedTaskIndex.literal(kind.rawValue)
                        + " AND state IN ('queued','running')", limit: kind == .summary ? Int.max : 1)
            }
            if kind == .summary {
                let normalized = summaryInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let matching = existing.first(where: {
                    $0.sourceRevision == sourceRevision && $0.providerID == providerID
                        && $0.summaryInstructions == (normalized?.isEmpty == false ? normalized : nil)
                }) {
                    return automatically ? matching.id : nil
                }
            }
            else {
                guard existing.isEmpty else { return nil }
            }
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return nil
        }
        // Retry/resume represents the same intent, so it updates the original row.
        // Only an explicitly new request after completion creates another row.
        var task: ManagedTaskRecord
        var existingIntent = false
        do {
            var previous = try await previousManagedIntent(kind: kind, meeting: meeting)
            if kind == .summary, let candidate = previous,
                candidate.state.isActive || candidate.sourceRevision != sourceRevision
                    || candidate.providerID != providerID || candidate.summaryInstructions != summaryInstructions
            {
                previous = nil
            }
            existingIntent = previous != nil
            task = previous ?? ManagedTaskRecord(kind: kind, meetingID: meeting.id, meetingTitle: meeting.title)
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return nil
        }
        if task.recovery == .restartRequired || task.restartRequested { return nil }
        if kind == .diarization, automatically, task.userStopped { return nil }
        if kind == .searchIndex {
            if task.userStopped, task.searchIndexRevision == searchIndexRevision, !retryStopped { return nil }
            task.searchIndexRevision = searchIndexRevision
        }
        task.batchID = batchID
        task.sourceRevision = sourceRevision
        task.providerID = providerID
        if kind == .summary, task.extractTodosAfterSummary == nil {
            task.extractTodosAfterSummary = settings.autoExtractTodos
        }
        if kind == .summary {
            let instructions = summaryInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            task.summaryInstructions = instructions?.isEmpty == false ? instructions : nil
        }
        task.providerName =
            providerID == ThisMacProvider.id
            ? "This Mac" : settings.serviceProviders.first { $0.id == providerID }?.name
        task.meetingTitle = meeting.title
        task.state = .queued
        task.progress =
            [.searchIndex, .diarization].contains(kind)
                && (recordingID != nil || isStartingRecording || isFinalizingRecording)
            ? "Waiting for recording to finish" : "Waiting to start"
        task.errorMessage = nil
        task.finishedAt = nil
        task.recovery = .automatic
        task.isAutomatic = automatically && (!existingIntent || task.isAutomatic)
        task.userStopped = false
        task.interrupted = false
        if kind == .diarization { task.speakerLabelingResultID = nil }
        if kind == .transcription, let attempt = meeting.transcriptionAttempt { task.capture(attempt) }
        guard batchID.map(isSearchRebuildActive) ?? true,
            kind != .searchIndex || !notesStorage.isEditing(meeting.id)
        else { return nil }
        if kind == .summary {
            do { try await reserveSummaryGeneration(task: task) }
            catch {
                managedTaskJournalError = "Couldn’t save the summary request. \(error.localizedDescription)"
                return nil
            }
        }
        if kind == .summary, !automatically {
            task.state = .paused
            task.recovery = .manual
            task.progress = "Preparing summary input…"
            guard await saveManagedTask(task) else { return nil }
            do {
                _ = try await prepareSummaryRequest(task: task, meetingSnapshot: meeting)
            }
            catch {
                task.state = .failed
                task.errorMessage = error.localizedDescription
                task.progress = "Failed"
                task.finishedAt = Date()
                _ = await saveManagedTask(task)
                return task.id
            }
            task.state = .queued
            task.recovery = .automatic
            task.progress = "Waiting to start"
        }
        guard await saveManagedTask(task) else { return nil }
        await startManagedTasks()
        return task.id
    }

    /// Speaker assignment changes do not create a new transcription result.
    /// For live/imported text without a provider receipt, hash the committed words.
    static func automaticTaskSource(_ meeting: Meeting, kind: BackgroundJob.Kind) -> String {
        let text = meeting.transcript.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var fields = [meeting.transcriptSource?.id.uuidString ?? "", text]
        if kind == .summary { fields.append(meeting.notes) }
        if kind == .diarization { fields += meeting.audioFiles }
        // Length prefixes keep field boundaries unambiguous without comparing whole meetings.
        let source = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func automaticTaskForSource(
        kind: BackgroundJob.Kind, meetingID: UUID, revision: String
    ) async throws -> ManagedTaskRecord? {
        let journal = managedTaskJournal
        let predicate =
            "meeting=" + ManagedTaskIndex.literal(meetingID.uuidString)
            + " AND kind=" + ManagedTaskIndex.literal(kind.rawValue)
        return try await managedTaskIO.perform {
            var cursor: ManagedTaskJournal.Cursor?
            while true {
                let page = journal.page(after: cursor, limit: 50, predicate: predicate)
                if let failure = journal.readFailure { throw failure }
                if let task = page.first(where: { $0.sourceRevision == revision }) { return task }
                guard page.count == 50, let last = page.last else { return nil }
                cursor = .init(createdAt: last.createdAt, id: last.id)
            }
        }
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

    func updateSearchMaintenanceBatch(scanActive: Bool? = nil) {
        let pending = [ManagedTaskState.queued, .running, .paused].contains { state in
            managedMaintenanceStateCounts[state, default: 0] > 0
                || managedTasks.contains { $0.isPreview && $0.isMaintenance && $0.state == state }
        }
        if pending {
            searchMaintenanceBatchActive = true
        }
        else if scanActive == false {
            searchMaintenanceBatchActive = false
        }
    }

    func invalidateTaskHistory(previous: ManagedTaskRecord?, current: ManagedTaskRecord?) {
        guard previous != current else { return }
        for scope in TaskHistoryScope.allCases
        where previous.map(scope.includes) == true || current.map(scope.includes) == true {
            managedTaskScopeRevisions[scope, default: 0] += 1
        }
    }

    /// Journal first: provider work must not start from an uncommitted intent.
    @discardableResult func saveManagedTask(_ proposed: ManagedTaskRecord) async -> Bool {
        var normalized = proposed
        if normalized.state != .running { normalized.progressDetails = nil }
        let proposed = normalized
        var task = proposed
        var previous = managedTask(id: proposed.id)
        let initialProgress = previous?.progressDetails
        if task.isPreview { task.recordTransition(from: managedTask(id: proposed.id)) }
        do {
            guard libraryWritable else { throw ServiceError("The meeting library is read-only.") }
            if !task.isPreview {
                let journal = managedTaskJournal
                let result = try await managedTaskIO.perform {
                    let previous = try journal.query(
                        where: "id=" + ManagedTaskIndex.literal(proposed.id.uuidString), limit: 1
                    ).first
                    var transitioned = proposed
                    transitioned.recordTransition(from: previous)
                    try journal.upsert(transitioned)
                    return (previous, transitioned)
                }
                task = result.1
                previous = result.0
                if let previous = result.0 {
                    managedTaskStateCounts[previous.state, default: 0] -= 1
                    if previous.needsAttention { managedTaskAttentionCount -= 1 }
                    if previous.isMaintenance { managedMaintenanceStateCounts[previous.state, default: 0] -= 1 }
                    for scope in TaskHistoryScope.allCases where scope.includes(previous) {
                        managedTaskScopeCounts[scope, default: 0] -= 1
                    }
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
                if task.needsAttention { managedTaskAttentionCount += 1 }
                if task.isMaintenance { managedMaintenanceStateCounts[task.state, default: 0] += 1 }
                for scope in TaskHistoryScope.allCases where scope.includes(task) {
                    managedTaskScopeCounts[scope, default: 0] += 1
                }
                if task.state.isActive { managedTaskActiveCounts[task.key, default: 0] += 1 }
            }
            // A provider can report progress while the journal write suspends.
            // Its live presentation is newer than the checkpoint we just saved.
            if task.state == .running, let live = managedTask(id: task.id), live.state == .running,
                live.progressDetails != initialProgress
            {
                task.progress = live.progress
                task.progressDetails = live.progressDetails
            }
            cacheManagedTask(task)
            updateSearchMaintenanceBatch()
            invalidateTaskHistory(previous: previous, current: task)
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

    func resumeSearchIndexingAfterRecording() {
        processingRecordingGeneration &+= 1
        let generation = processingRecordingGeneration
        Task {
            await ProcessingCoordinator.shared.setMaintenanceSuspended(
                false, generation: generation, owner: processingRecordingOwner)
            guard processingRecordingGeneration == generation, recordingID == nil,
                !isStartingRecording, !isFinalizingRecording
            else { return }
            if localSearch.deferredRecordingChanges || localSearch.scanRequested {
                localSearch.deferredRecordingChanges = false
                scheduleSearchIndexing()
            }
            await recoverUnfinishedManagedTasks()
        }
    }

    func suspendSearchIndexingForRecording() async {
        processingRecordingGeneration &+= 1
        await ProcessingCoordinator.shared.setMaintenanceSuspended(
            true, generation: processingRecordingGeneration, owner: processingRecordingOwner)
        let running = managedTasks.filter { $0.kind == .searchIndex && $0.state == .running }
        for task in running { managedMaintenancePauseRequests.insert(task.id) }
        let operations = running.compactMap { managedTaskOperations[$0.id] }
        for operation in operations { operation.cancel() }
        let generation = processingRecordingGeneration
        Task { [weak self] in
            for operation in operations { await operation.value }
            guard let self, self.processingRecordingGeneration == generation else { return }
            await self.localSearch.pauseIndexingForRecording()
        }
    }

    func startManagedTasks() async {
        guard !isChangingLibrary, !isPreparingToQuit, !isSchedulingManagedTasks, !managedTasksLoading else { return }
        isSchedulingManagedTasks = true
        defer { isSchedulingManagedTasks = false }
        for kind in [
            BackgroundJob.Kind.transcription, .diarization, .speakerAssociation, .summary, .todoExtraction,
            .searchIndex,
        ] {
            if [.searchIndex, .diarization].contains(kind),
                recordingID != nil || isStartingRecording || isFinalizingRecording
            {
                continue
            }
            let limit =
                kind == .transcription
                ? Self.maximumConcurrentTranscriptions
                : kind == .searchIndex
                    ? 1 : kind == .diarization ? Self.maximumConcurrentSpeakerLabeling : Self.maximumConcurrentSummaries
            while true {
                let running = managedTasks.filter { $0.kind == kind && $0.state == .running && !$0.isPreview }.count
                guard running < limit else { break }
                let excludedMeetings = deletingMeetingIDs.map { ManagedTaskIndex.literal($0.uuidString) }.joined(
                    separator: ",")
                let deletionPredicate = excludedMeetings.isEmpty ? "" : " AND meeting NOT IN (\(excludedMeetings))"
                let candidates: [ManagedTaskRecord]
                do {
                    candidates = try await runnableManagedTasks(
                        kind: kind, limit: limit - running,
                        excluding: deletionPredicate)
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
                    guard !deletingMeetingIDs.contains(candidate.meetingID) else { continue }
                    if [.searchIndex, .diarization].contains(kind),
                        recordingID != nil || isStartingRecording || isFinalizingRecording
                    {
                        return
                    }
                    let id = candidate.id
                    var task = candidate
                    cacheManagedTask(task)
                    if managedTaskStopRequests.contains(id)
                        || task.batchID.map({ !isSearchRebuildActive($0) }) == true
                        || (task.pipelineID == nil && task.kind == .summary && task.isAutomatic
                            && !settings.autoSummarize)
                        || (task.pipelineID == nil && task.kind == .diarization && task.isAutomatic
                            && !settings.labelRecordedSpeakers)
                    {
                        await cancelManagedTaskCommand(id: id)
                        // A rejected durable transition must not retry the same head forever.
                        guard managedTaskActiveCounts[task.key, default: 0] == 0 else { return }
                        continue
                    }
                    task.state = .running
                    task.progress = "Starting…"
                    task.progressDetails = TaskProgress(phase: "Starting…")
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
                    if deletingMeetingIDs.contains(task.meetingID)
                        || ([.searchIndex, .diarization].contains(kind)
                            && (recordingID != nil || isStartingRecording || isFinalizingRecording))
                    {
                        task.state = .queued
                        task.progress =
                            deletingMeetingIDs.contains(task.meetingID)
                            ? "Waiting to start" : "Waiting for recording to finish"
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
                try Task.checkCancellation()
                if await managedTaskMeetingIsMissing(task.meetingID) { throw MissingManagedTaskMeeting() }
                throw ServiceError("Couldn’t read this meeting. Check that the library is available, then retry.")
            }
            try Task.checkCancellation()
            if let batchID = task.batchID, !isSearchRebuildActive(batchID) { throw CancellationError() }
            if try meeting.completedTaskIDs[task.kind.rawValue] == task.id
                || (task.kind == .summary && hasCompletedSummary(taskID: task.id, meetingID: task.meetingID))
            {
                await completeManagedTask(id, state: .completed, recovery: .none)
                return
            }
            if task.pipelineOutcome == .disabled {
                await completeManagedTask(
                    id, state: .completed, recovery: .none,
                    message: "Skipped because this step is turned off.")
                return
            }
            if let reason = try await pipelineNoDataReason(task, meeting: meeting) {
                try Task.checkCancellation()
                let dependencies = try await pipelineDependencyRecords(task)
                let awaitingSummary =
                    task.kind == .todoExtraction
                    && dependencies.contains {
                        $0.kind == .summary && $0.pipelineOutcome != .disabled
                            && ($0.state != .completed || $0.pipelineOutcome == .noData)
                    }
                await completeManagedTask(
                    id, state: .completed, recovery: .none, message: reason,
                    outcome: awaitingSummary ? .noSummaryResult : .noData)
                return
            }
            switch task.kind {
            case .transcription:
                try await performTranscription(id: task.meetingID, providerID: task.providerID)
            case .summary:
                if task.pipelineID == nil && task.kind == .summary && task.isAutomatic && !settings.autoSummarize {
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
            case .speakerAssociation:
                try await performPipelineSpeakerAssociation(id: task.meetingID)
            case .todoExtraction:
                try await performPipelineTodoExtraction(task)
            default: throw ServiceError("This task type cannot run from Tasks yet.")
            }
            try Task.checkCancellation()
            await completeManagedTask(id, state: .completed, recovery: .none)
            if task.kind == .transcription && task.pipelineID == nil {
                await scheduleAutomaticSpeakerLabeling(id: task.meetingID)
            }
            if task.kind == .searchIndex { scheduleSearchIndexing() }
        }
        catch {
            let missingMeeting: Bool
            if error is MissingManagedTaskMeeting {
                missingMeeting = true
            }
            else {
                missingMeeting = await managedTaskMeetingIsMissing(task.meetingID)
            }
            if missingMeeting, !hasCommittedTaskReceipt(task) {
                await completeManagedTask(
                    id, state: .cancelled, recovery: .none,
                    message: MissingManagedTaskMeeting().localizedDescription)
            }
            else if Task.isCancelled || error is CancellationError {
                let hasReceipt = hasCommittedTaskReceipt(task)
                if hasReceipt {
                    // Cancellation cannot undo a result already committed with its receipt.
                    await completeManagedTask(id, state: .completed, recovery: .none)
                }
                else if task.kind == .searchIndex,
                    managedMaintenancePauseRequests.contains(id),
                    !managedTaskStopRequests.contains(id)
                {
                    await completeManagedTask(
                        id, state: .paused, recovery: .automatic,
                        message: "Waiting for recording to finish")
                }
                else if isPreparingToQuit && !managedTaskStopRequests.contains(id) {
                    await completeManagedTask(
                        id, state: .failed,
                        recovery: [.transcription, .searchIndex].contains(task.kind) ? .automatic : .manual,
                        message: "Interrupted when the app closed.")
                }
                else {
                    await completeManagedTask(
                        id, state: .cancelled, recovery: .manual,
                        message: task.kind == .searchIndex
                            ? "Search indexing stopped."
                            : task.kind == .diarization
                                ? "Speaker diarization cancelled. The current transcript was kept."
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

    func completeManagedTask(
        _ id: UUID, state: ManagedTaskState, recovery: ManagedTaskRecovery, message: String? = nil,
        outcome: RecordingPipelineOutcome? = nil
    ) async {
        await managedTaskCommands.run {
            let journal = self.managedTaskJournal
            do {
                let latest = try await self.managedTaskIO.perform {
                    try journal.query(where: "id=" + ManagedTaskIndex.literal(id.uuidString), limit: 1).first
                }
                if let latest, latest.state == .cancelled, latest.recovery == .none {
                    self.cacheManagedTask(latest)
                    // A delayed worker cannot undo a terminal cancellation. A result
                    // already committed to the meeting still takes precedence.
                    guard self.hasCommittedTaskReceipt(latest) else { return }
                    await self.finishManagedTask(id, state: .completed, recovery: .none)
                    return
                }
            }
            catch {
                self.managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
                return
            }
            await self.finishManagedTask(id, state: state, recovery: recovery, message: message, outcome: outcome)
        }
    }

    private func finishManagedTask(
        _ id: UUID, state: ManagedTaskState, recovery: ManagedTaskRecovery, message: String? = nil,
        outcome: RecordingPipelineOutcome? = nil
    ) async {
        guard var task = managedTask(id: id) else { return }
        task.state = state
        task.progressDetails = nil
        task.recovery = recovery
        task.finishedAt = state == .paused ? nil : Date()
        task.errorMessage = message
        if let outcome { task.pipelineOutcome = outcome }
        if state == .completed, task.pipelineID != nil, task.pipelineOutcome == nil {
            task.pipelineOutcome = .completed
        }
        task.progress =
            state == .completed
            ? (task.pipelineOutcome == .noData || task.pipelineOutcome == .noSummaryResult
                || task.pipelineOutcome == .disabled ? message ?? "Skipped" : "Completed")
            : state == .cancelled ? "Cancelled" : state == .paused ? message ?? "Paused" : "Failed"
        task.attentionAcknowledged = false
        let committed = await saveManagedTask(task)
        if committed {
            managedTaskStopRequests.remove(id)
        }
        else {
            // The result receipt, committed with meeting content, protects recovery.
            if let index = managedTasks.firstIndex(where: { $0.id == id }) { managedTasks[index] = task }
        }
        let ownedOperation = managedTaskOperations.removeValue(forKey: id) != nil
        managedMaintenancePauseRequests.remove(id)
        if committed, task.state == .paused, task.recovery == .automatic,
            recordingID == nil, !isStartingRecording, !isFinalizingRecording, !isPreparingToQuit
        {
            var resumed = task
            resumed.state = .queued
            resumed.progress = "Waiting to resume"
            resumed.errorMessage = nil
            _ = await saveManagedTask(resumed)
        }
        if ownedOperation { endJob(task.kind, .meeting(task.meetingID)) }
        if state == .completed && task.kind == .summary { await resumePipelineTodoAfterSummary(task) }
        for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        await reloadExternalManagedTasksCommand()
        await startManagedTasks()
        if task.kind == .summary { startPendingAutomaticSummary(id: task.meetingID) }
        if task.kind == .searchIndex, !isPreparingToQuit, !isChangingLibrary { scheduleSearchIndexing() }
    }

    private func failUncommittedTask(_ task: ManagedTaskRecord) {
        if let index = managedTasks.firstIndex(where: { $0.id == task.id }) {
            managedTasks[index].state = .failed
            managedTasks[index].recovery = .manual
            managedTasks[index].errorMessage = managedTaskJournalError
        }
        for waiter in managedTaskWaiters.removeValue(forKey: task.id) ?? [] { waiter.resume() }
    }

    func cancelManagedTaskCommand(id: UUID, userInitiated: Bool = true) async {
        guard managedTask(id: id)?.kind != .recordingFinalization else { return }
        guard var task = managedTask(id: id), task.state.isActive || task.state == .paused else {
            managedTaskStopRequests.remove(id)
            return
        }
        if task.kind == .summary { pendingAutomaticSummaries.remove(task.meetingID) }
        task.userStopped = userInitiated
        task.recovery = .manual
        task.progress = "Stopping…"
        guard await saveManagedTask(task) else {
            if task.state == .queued { failUncommittedTask(task) }
            return
        }
        if task.state == .queued || task.state == .paused || task.isPreview {
            await finishManagedTask(
                id, state: .cancelled, recovery: .manual,
                message: task.state == .queued ? "Removed before it started." : "Stopped waiting on this Mac.")
        }
        else {
            managedTaskOperations[id]?.cancel()
        }
    }

    func cancelTasksForDeletedMeeting(_ meetingID: UUID) async {
        await managedTaskCommands.run {
            let journal = self.managedTaskJournal
            let wasScheduling = self.isSchedulingManagedTasks
            self.isSchedulingManagedTasks = true
            defer { self.isSchedulingManagedTasks = wasScheduling }
            do {
                var cursor: ManagedTaskJournal.Cursor?
                while true {
                    let after = cursor
                    let tasks = try await self.managedTaskIO.perform {
                        let records = journal.page(
                            after: after, limit: 50,
                            predicate: "meeting=" + ManagedTaskIndex.literal(meetingID.uuidString)
                                + " AND state NOT IN ('completed','cancelled')")
                        if let error = journal.readFailure { throw error }
                        return records
                    }
                    guard let last = tasks.last else { break }
                    for task in tasks {
                        self.cacheManagedTask(task)
                        await self.finishManagedTask(
                            task.id, state: .cancelled, recovery: .none, message: "Meeting was deleted.")
                    }
                    cursor = .init(createdAt: last.createdAt, id: last.id)
                }
            }
            catch { self.managedTaskJournalError = "Couldn’t update tasks. \(error.localizedDescription)" }
        }
    }

    func canRetryManagedTask(_ task: ManagedTaskRecord) -> Bool {
        guard task.state == .failed || task.state == .cancelled || task.state == .paused,
            !isJobRunning(task.kind, .meeting(task.meetingID)), !task.dismissRequested, !task.restartRequested,
            task.recovery != .restartRequired && task.recovery != .blocked && task.recovery != .none
        else { return false }
        if task.isPreview || task.kind == .summary { return true }
        if [.speakerAssociation, .todoExtraction].contains(task.kind) { return true }
        if task.kind == .searchIndex { return selectedSearchProvider != nil }
        if task.kind == .diarization {
            return recordingID != task.meetingID && !isJobRunning(.transcription, .meeting(task.meetingID))
                && !isJobRunning(.importAudio, .meeting(task.meetingID))
                && settings.serviceProviders.contains {
                    $0.id == task.providerID && $0.kind == .speakerLabeling && $0.supports(.diarization)
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
        task.state == .paused || task.kind == .transcription && (task.interrupted || task.attemptKey != nil)
            ? "Resume" : "Retry"
    }

    func retryManagedTaskCommand(id: UUID) async {
        guard let task = managedTask(id: id), canRetryManagedTask(task) else { return }
        if task.isPreview {
            await finishManagedTask(id, state: .completed, recovery: .none)
            return
        }
        guard await ensureMeetingLoaded(id: task.meetingID), canRetryManagedTask(task) else { return }
        if task.pipelineID != nil {
            var retry = task
            retry.state = .queued
            retry.recovery = .automatic
            retry.errorMessage = nil
            retry.finishedAt = nil
            retry.pipelineOutcome = nil
            retry.userStopped = false
            guard await saveManagedTask(retry) else { return }
            await startManagedTasks()
        }
        else if task.kind == .transcription {
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

    func dismissManagedTaskAlertCommand(id: UUID) async {
        guard var task = managedTask(id: id), task.needsAttention else { return }
        task.attentionAcknowledged = true
        _ = await saveManagedTask(task)
    }

    func removeManagedTaskCommand(id: UUID) async {
        guard var task = managedTask(id: id), task.state != .running else { return }
        if task.state == .queued { await cancelManagedTaskCommand(id: id) }
        guard managedTaskOperations[id] == nil else { return }
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
        if task.pipelineID != nil {
            // The dependency identity remains durable after its work is discarded.
            // Deleting it would strand surviving downstream nodes on recovery.
            var discarded = task
            discarded.state = .cancelled
            discarded.recovery = .none
            discarded.dismissRequested = false
            discarded.userStopped = true
            discarded.attentionAcknowledged = true
            discarded.errorMessage = nil
            discarded.progress = "Discarded"
            discarded.finishedAt = Date()
            guard await saveManagedTask(discarded) else { return }
            managedTaskStopRequests.remove(task.id)
            await startManagedTasks()
            return
        }
        do {
            if !task.isPreview {
                let journal = managedTaskJournal
                try await managedTaskIO.perform { try journal.delete(task.id) }
                managedTaskStateCounts[task.state, default: 0] -= 1
                if task.needsAttention { managedTaskAttentionCount -= 1 }
                if task.isMaintenance { managedMaintenanceStateCounts[task.state, default: 0] -= 1 }
                for scope in TaskHistoryScope.allCases where scope.includes(task) {
                    managedTaskScopeCounts[scope, default: 0] -= 1
                }
            }
            managedTasks.removeAll { $0.id == task.id }
            managedTaskStopRequests.remove(task.id)
            updateSearchMaintenanceBatch(scanActive: localSearch.scanTask != nil)
            invalidateTaskHistory(previous: task, current: nil)
            managedTaskRevision += 1
        }
        catch { managedTaskJournalError = "Couldn’t discard this task. \(error.localizedDescription)" }
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
                        let recordID = record.id
                        let changed = try await managedTaskIO.perform { try journal.changedSinceRebuild(recordID) }
                        record.state = changed ? .paused : .failed
                        record.recovery = .manual
                        record.attentionAcknowledged = false
                        record.progress = changed ? "Paused" : "Failed"
                        record.errorMessage =
                            changed
                            ? "This task changed outside the app. Resume to continue."
                            : "This task has no running operation. Review it before retrying."
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

    func applyManagedTaskSnapshot(_ snapshot: ManagedTaskSnapshot) {
        let recentIDs = Set(snapshot.recent.map(\.id))
        let pinned = managedTasks.filter {
            !recentIDs.contains($0.id) && ($0.isPreview || managedTaskOperations[$0.id] != nil)
        }
        managedTasks = snapshot.recent + pinned
        managedTaskStateCounts = snapshot.counts
        managedTaskAttentionCount = snapshot.attentionCount
        managedTaskScopeCounts = snapshot.scopeCounts
        managedMaintenanceStateCounts = snapshot.maintenanceCounts
        updateSearchMaintenanceBatch(scanActive: localSearch.scanTask != nil)
        managedTaskActiveCounts = snapshot.activeCounts
        for id in Array(managedTaskWaiters.keys)
        where !snapshot.activeIDs.contains(id) && managedTaskOperations[id] == nil {
            for waiter in managedTaskWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        }
        for scope in TaskHistoryScope.allCases { managedTaskScopeRevisions[scope, default: 0] += 1 }
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
                let records = journal.page(
                    after: cursor, limit: 50, predicate: "(state!='completed' OR kind='todoExtraction')")
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
            if original.kind == .todoExtraction && original.pipelineOutcome == .noSummaryResult {
                do {
                    if let summary = try await pipelineDependencyRecords(original).first(where: { $0.kind == .summary })
                    {
                        await resumePipelineTodoAfterSummary(summary)
                    }
                }
                catch {
                    managedTaskJournalError = "Couldn’t recover to-do extraction. \(error.localizedDescription)"
                }
            }
            guard original.state != .completed,
                !(original.state == .cancelled && original.recovery == .none)
            else { continue }
            if let batchID = original.batchID, !isSearchRebuildActive(batchID),
                original.state.isActive || original.state == .paused
            {
                await cancelManagedTaskCommand(id: original.id)
                continue
            }
            guard await ensureMeetingLoaded(id: original.meetingID),
                let meeting = meetings.first(where: { $0.id == original.meetingID })
            else {
                if await managedTaskMeetingIsMissing(original.meetingID) {
                    await finishManagedTask(
                        original.id, state: .cancelled, recovery: .none,
                        message: MissingManagedTaskMeeting().localizedDescription)
                }
                else if original.state.isActive || original.state == .paused {
                    await finishManagedTask(
                        original.id, state: .failed, recovery: .manual,
                        message: "Couldn’t read this meeting. Check that the library is available, then retry.")
                }
                continue
            }
            if meeting.completedTaskIDs[original.kind.rawValue] == original.id
                || (original.kind == .summary
                    && ((try? hasCompletedSummary(taskID: original.id, meetingID: original.meetingID)) == true))
            {
                await finishManagedTask(original.id, state: .completed, recovery: .none)
                continue
            }
            guard
                original.state.isActive
                    || ([.failed, .paused].contains(original.state) && original.recovery == .automatic)
            else {
                continue
            }
            if original.kind == .recordingFinalization {
                if recordingID == original.meetingID || isFinalizingRecording { continue }
                await finishManagedTask(
                    original.id, state: .failed, recovery: .blocked,
                    message: "Recording finalization was interrupted. Review its saved audio before processing.")
                continue
            }
            guard
                [.transcription, .summary, .diarization, .speakerAssociation, .todoExtraction, .searchIndex].contains(
                    original.kind)
            else {
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
            if task.kind == .diarization, task.state != .queued {
                await finishManagedTask(
                    task.id, state: .failed, recovery: .manual,
                    message: "Speaker diarization was interrupted. Retry starts analysis again.")
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
                        "The saved transcription request is missing. Discard this task before starting another transcription."
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

    func recordManagedTaskProgress(_ key: BackgroundJob.Key, progress: String, details: TaskProgress? = nil) {
        guard var task = managedTasks.first(where: { $0.key == key && $0.state == .running }),
            task.progress != progress || task.progressDetails != details
        else { return }
        task.progress = progress
        task.progressDetails = details
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
            throw ServiceError(managedTaskJournalError ?? "Couldn’t save the speaker-diarization task.")
        }
    }

    func markManagedTaskCompletion(on meeting: inout Meeting, kind: BackgroundJob.Kind) {
        if let task = managedTasks.first(where: {
            $0.kind == kind && $0.meetingID == meeting.id && $0.state == .running
        }) {
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
