import Foundation

extension MeetingStore {
    private func enqueueCommand(
        kind: BackgroundJob.Kind, meetingID: UUID,
        operation: @escaping @MainActor () async -> UUID?
    ) async -> UUID? {
        let key = BackgroundJob.Key(kind: kind, scope: .meeting(meetingID))
        guard !isChangingLibrary, !isPreparingToQuit, !isJobRunning(kind, .meeting(meetingID)) else { return nil }
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
        await enqueueCommand(kind: .summary, meetingID: id) {
            await self.queueSummaryCommand(
                id: id, providerID: providerID, automatically: automatically, instructions: instructions)
        }
    }

    @discardableResult func queueSpeakerLabeling(id: UUID, providerID: UUID? = nil) async -> UUID? {
        await enqueueCommand(kind: .diarization, meetingID: id) {
            await self.queueSpeakerLabelingCommand(id: id, providerID: providerID)
        }
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

    func removeManagedTask(id: UUID) async {
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
