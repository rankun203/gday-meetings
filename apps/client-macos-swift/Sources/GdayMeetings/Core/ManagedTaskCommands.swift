import Foundation

extension MeetingStore {
    private func enqueueCommand(
        kind: BackgroundJob.Kind, meetingID: UUID,
        operation: @escaping @MainActor () async -> UUID?
    ) async -> UUID? {
        let key = BackgroundJob.Key(kind: kind, scope: .meeting(meetingID))
        guard !isChangingLibrary, !isPreparingToQuit,
            kind == .searchIndex || !isJobRunning(kind, .meeting(meetingID))
        else { return nil }
        managedTaskReservations.insert(key)
        defer { managedTaskReservations.remove(key) }
        await managedTaskPreparation?.value
        return await managedTaskCommands.run(operation)
    }

    @discardableResult func queueTranscription(id: UUID, providerID: UUID? = nil) async -> UUID? {
        await enqueueCommand(kind: .transcription, meetingID: id) {
            await self.queueTranscriptionCommand(id: id, providerID: providerID)
        }
    }

    @discardableResult func queueSummary(
        id: UUID, providerID: UUID? = nil, automatically: Bool = false, instructions: String? = nil
    ) async -> UUID? {
        let key = BackgroundJob.Key(kind: .summary, scope: .meeting(id))
        guard !managedTaskReservations.contains(key), !isChangingLibrary, !isPreparingToQuit else { return nil }
        managedTaskReservations.insert(key)
        if !automatically { pendingAutomaticSummaries.remove(id) }
        defer { managedTaskReservations.remove(key) }
        await managedTaskPreparation?.value
        return await managedTaskCommands.run {
            await self.queueSummaryCommand(
                id: id, providerID: providerID, automatically: automatically, instructions: instructions)
        }
    }

    @discardableResult func queueSpeakerLabeling(
        id: UUID, providerID: UUID? = nil, automatically: Bool = false
    ) async -> UUID? {
        await supersedeObsoleteTask(kind: .diarization, meetingID: id)
        return await enqueueCommand(kind: .diarization, meetingID: id) {
            await self.queueSpeakerLabelingCommand(id: id, providerID: providerID, automatically: automatically)
        }
    }

    @discardableResult func queueSearchIndex(id: UUID, revision: String, force: Bool = false, batchID: UUID? = nil)
        async -> UUID?
    {
        await enqueueCommand(kind: .searchIndex, meetingID: id) {
            await self.queueSearchIndexCommand(id: id, revision: revision, force: force, batchID: batchID)
        }
    }

    /// Editing suspends obsolete work without recording a user cancellation.
    func suspendSearchIndexForEditing(id: UUID) async {
        await managedTaskPreparation?.value
        guard
            let active = managedTasks.first(where: {
                $0.kind == .searchIndex && $0.meetingID == id && $0.state.isActive
            })
        else { return }
        await taskCommand(id: active.id) {
            await self.cancelManagedTaskCommand(id: active.id, userInitiated: false)
        }
    }

    func isSearchRebuildActive(_ batchID: UUID) -> Bool {
        localSearch.rebuildRequest?.id == batchID && localSearch.rebuildRequest?.isActive == true
    }

    func managedTasksForBatch(_ batchID: UUID) async throws -> [ManagedTaskRecord] {
        await managedTaskPreparation?.value
        let journal = managedTaskJournal
        return try await managedTaskIO.perform {
            var result: [ManagedTaskRecord] = []
            var cursor: ManagedTaskJournal.Cursor?
            while true {
                let page = journal.page(after: cursor, limit: 100, predicate: "kind='searchIndex'")
                if let failure = journal.readFailure { throw failure }
                result += page.filter { $0.batchID == batchID }
                guard page.count == 100, let last = page.last else { return result }
                cursor = .init(createdAt: last.createdAt, id: last.id)
            }
        }
    }

    @discardableResult func cancelManagedTaskBatch(_ batchID: UUID) async -> Bool {
        do {
            for record in try await managedTasksForBatch(batchID)
            where record.state.isActive || record.state == .paused {
                await cancelManagedTask(id: record.id)
                if let latest = managedTask(id: record.id), latest.state.isActive && !latest.userStopped {
                    return false
                }
            }
            return true
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return false
        }
    }

    /// Wait outside the serialized command queue: completion must enter that queue
    /// to release the old operation before its replacement can start.
    private func supersedeObsoleteTask(
        kind: BackgroundJob.Kind, meetingID: UUID, explicitSummary: Bool = false,
        providerID: UUID? = nil, instructions: String? = nil
    ) async {
        await managedTaskPreparation?.value
        guard await ensureMeetingLoaded(id: meetingID), let meeting = meeting(id: meetingID),
            let active = managedTasks.first(where: {
                $0.kind == kind && $0.meetingID == meetingID && $0.state.isActive
            })
        else { return }
        let sourceChanged = active.sourceRevision.map { $0 != Self.automaticTaskSource(meeting, kind: kind) } ?? false
        let normalizedInstructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedInstructions = normalizedInstructions?.isEmpty == false ? normalizedInstructions : nil
        let requestChanged =
            explicitSummary
            && (active.providerID != providerID || active.summaryInstructions != requestedInstructions)
        guard sourceChanged || requestChanged else { return }
        await taskCommand(id: active.id) {
            await self.cancelManagedTaskCommand(id: active.id, userInitiated: false)
        }
        await waitForManagedTask(active.id)
    }

    func loadManagedTask(id: UUID) async -> ManagedTaskRecord? {
        await managedTaskPreparation?.value
        return await managedTaskCommands.run { await self.loadManagedTaskCommand(id: id) }
    }

    private func loadManagedTaskCommand(id: UUID) async -> ManagedTaskRecord? {
        guard !isChangingLibrary else { return nil }
        if let cached = managedTask(id: id) { return cached }
        let journal = managedTaskJournal
        do {
            let record = try await managedTaskIO.perform {
                try journal.query(where: "id=" + ManagedTaskIndex.literal(id.uuidString), limit: 1).first
            }
            if let record { cacheManagedTask(record) }
            return record
        }
        catch {
            managedTaskJournalError = "Couldn’t read tasks. \(error.localizedDescription)"
            return nil
        }
    }

    private func taskCommand(id: UUID, operation: @escaping @MainActor () async -> Void) async {
        await managedTaskPreparation?.value
        await managedTaskCommands.run {
            guard !self.isPreparingToQuit, await self.loadManagedTaskCommand(id: id) != nil else { return }
            await operation()
        }
    }

    func cancelManagedTask(id: UUID) async {
        guard managedTask(id: id)?.kind != .recordingFinalization else { return }
        managedTaskStopRequests.insert(id)
        managedTaskOperations[id]?.cancel()
        await taskCommand(id: id) { await self.cancelManagedTaskCommand(id: id) }
    }

    func retryManagedTask(id: UUID) async {
        await taskCommand(id: id) {
            self.managedTaskStopRequests.remove(id)
            await self.retryManagedTaskCommand(id: id)
        }
    }

    func restartManagedTask(id: UUID) async {
        await taskCommand(id: id) {
            self.managedTaskStopRequests.remove(id)
            await self.restartManagedTaskCommand(id: id)
        }
    }

    func prioritizeManagedTask(id: UUID) async {
        await taskCommand(id: id) { await self.prioritizeManagedTaskCommand(id: id) }
    }

    func dismissAllTaskAlerts() async {
        while true {
            let page = await taskHistoryPage(scope: .attention)
            guard !page.isEmpty else { return }
            let count = taskAttentionCount
            for row in page {
                switch row {
                case .managed(let task): await dismissManagedTaskAlert(id: task.id)
                case .voice(let job): voicePreparation.dismissAlert(jobID: job.id)
                }
            }
            // Stop if persistence rejected an acknowledgement.
            guard taskAttentionCount < count else { return }
        }
    }

    func dismissManagedTaskAlert(id: UUID) async {
        await taskCommand(id: id) { await self.dismissManagedTaskAlertCommand(id: id) }
    }

    func removeManagedTask(id: UUID) async {
        if let task = managedTask(id: id), task.kind == .recordingFinalization && task.state.isActive { return }
        managedTaskStopRequests.insert(id)
        await taskCommand(id: id) { await self.removeManagedTaskCommand(id: id) }
    }

    func reloadExternalManagedTasks() async {
        guard !isChangingLibrary, !isPreparingToQuit else { return }
        await managedTaskCommands.run { await self.reloadExternalManagedTasksCommand() }
    }

    func recoverUnfinishedManagedTasks() async {
        guard !isChangingLibrary, !isPreparingToQuit else { return }
        await managedTaskPreparation?.value
        guard !isChangingLibrary, !isPreparingToQuit else { return }
        await managedTaskCommands.run { await self.recoverUnfinishedManagedTasksCommand() }
    }

    func restoreManagedTasks() async throws {
        let result: Result<Void, Error> = await managedTaskCommands.run {
            do {
                try await self.restoreManagedTasksCommand()
                return .success(())
            }
            catch { return .failure(error) }
        }
        try result.get()
    }

    func bindManagedTranscriptionAttempt(_ attempt: ProviderTranscriptionAttempt, meetingID: UUID) async throws {
        let result: Result<Void, Error> = await managedTaskCommands.run {
            do {
                try await self.bindManagedTranscriptionAttemptCommand(attempt, meetingID: meetingID)
                return .success(())
            }
            catch { return .failure(error) }
        }
        try result.get()
        try Task.checkCancellation()
    }

    func bindSpeakerLabelingResult(_ resultID: UUID, meetingID: UUID) async throws {
        let result: Result<Void, Error> = await managedTaskCommands.run {
            do {
                try await self.bindSpeakerLabelingResultCommand(resultID, meetingID: meetingID)
                return .success(())
            }
            catch { return .failure(error) }
        }
        try result.get()
        try Task.checkCancellation()
    }

    func reconcileManagedTaskCompletion(for meeting: Meeting, kind: BackgroundJob.Kind) async {
        await managedTaskCommands.run {
            if let id = meeting.completedTaskIDs[kind.rawValue] { _ = await self.loadManagedTaskCommand(id: id) }
            await self.reconcileManagedTaskCompletionCommand(for: meeting, kind: kind)
        }
    }

    func waitForManagedTask(_ id: UUID) async {
        await managedTaskPreparation?.value
        await withCheckedContinuation { waiter in
            Task { @MainActor in
                await self.managedTaskCommands.run {
                    guard let record = await self.loadManagedTaskCommand(id: id), record.state.isActive else {
                        waiter.resume()
                        return
                    }
                    // Register in the same command as the load. Completion cannot run
                    // between a cold history read and installing its waiter.
                    self.managedTaskWaiters[id, default: []].append(waiter)
                }
            }
        }
    }

    /// Freeze user admissions, stop provider operations, then drain their final
    /// checkpoints. Provider work is awaited outside the command gate.
    func prepareManagedTasksForQuit() async -> Bool {
        isPreparingToQuit = true
        managedTaskShutdownError = nil
        let operations = Array(managedTaskOperations.values)
        for operation in operations { operation.cancel() }
        await managedTaskPreparation?.value
        await managedTaskCommands.drain()
        for operation in operations { await operation.value }
        await managedTaskCommands.drain()
        return managedTaskShutdownError == nil
    }

    func flushManagedTaskCommands() async {
        await managedTaskPreparation?.value
        await managedTaskCommands.drain()
    }
}
