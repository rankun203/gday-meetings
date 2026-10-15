import Foundation

enum RecordingPipelineOutcome: String, Codable, Sendable {
    case completed, disabled, noData, noSummaryResult
}

/// The graph is admitted atomically before capture stops. Ordinary task recovery
/// and scheduling own every subsequent transition.
enum RecordingPipeline {
    static func isSettled(_ task: ManagedTaskRecord) -> Bool {
        !task.state.isActive && task.state != .paused
            && !(task.state == .failed && task.recovery == .automatic)
    }
    static func tasks(meeting: Meeting, settings: AppSettings, transcribeAfter: Bool) -> [ManagedTaskRecord] {
        let run = UUID()
        var records: [ManagedTaskRecord] = []
        func node(
            _ kind: BackgroundJob.Kind, enabled: Bool = true, dependencies: [UUID] = [],
            provider: UUID? = nil
        ) -> UUID {
            var task = ManagedTaskRecord(kind: kind, meetingID: meeting.id, meetingTitle: meeting.title)
            task.pipelineID = run
            task.dependencyIDs = dependencies
            task.providerID = provider
            task.providerName =
                provider == ThisMacProvider.id
                ? "This Mac"
                : settings.serviceProviders.first(where: { $0.id == provider })?.name
            task.isAutomatic = true
            task.extractTodosAfterSummary = false
            if !enabled {
                task.pipelineOutcome = .disabled
                task.progress = "Waiting for dependencies; this step is turned off."
            }
            else {
                task.progress = "Waiting for dependencies"
            }
            task.recordTransition(from: nil)
            records.append(task)
            return task.id
        }
        let saved = node(.recordingFinalization)
        records[0].progress = "Saving recording…"
        records[0].state = .running
        let transcript = node(
            .transcription, enabled: transcribeAfter && settings.autoTranscribe,
            dependencies: [saved], provider: settings.transcriptionProviderID)
        records[records.count - 1].preferFinalizedLiveTranscript = !settings.autoTranscribeEvenWithLiveTranscript
        let labels = node(
            .diarization, enabled: settings.labelRecordedSpeakers,
            dependencies: [saved, transcript], provider: settings.diarizationProviderID)
        let people = node(
            .speakerAssociation, enabled: settings.recognizeSpeakers,
            dependencies: [saved, labels])
        let summary = node(
            .summary, enabled: settings.autoSummarize,
            dependencies: [saved, transcript, labels, people], provider: settings.summaryProviderID)
        _ = node(
            .todoExtraction, enabled: settings.autoExtractTodos,
            dependencies: [saved, summary])
        return records
    }
}

extension MeetingStore {
    /// Returns the same graph when Stop is retried for this recording.
    func admitRecordingPipeline(id: UUID, transcribeAfter: Bool) async -> UUID? {
        await managedTaskPreparation?.value
        return await managedTaskCommands.run {
            guard self.libraryWritable, let meeting = self.meeting(id: id) else { return nil }
            let journal = self.managedTaskJournal
            do {
                let existing = try await self.managedTaskIO.perform {
                    try journal.query(
                        where: "meeting=" + ManagedTaskIndex.literal(id.uuidString)
                            + " AND kind='recordingFinalization'", limit: 1
                    ).first
                }
                if let existing { return existing.id }
                let tasks = RecordingPipeline.tasks(
                    meeting: meeting, settings: self.settings,
                    transcribeAfter: transcribeAfter)
                for task in tasks where task.kind == .summary && task.pipelineOutcome != .disabled {
                    try await self.reserveSummaryGeneration(task: task)
                }
                let snapshot = try await self.managedTaskIO.perform {
                    try journal.upsertBatch(tasks)
                    return try ManagedTaskSnapshot.read(journal)
                }
                self.applyManagedTaskSnapshot(snapshot)
                return tasks.first?.id
            }
            catch {
                self.managedTaskJournalError =
                    "Couldn’t save the recording’s processing tasks. \(error.localizedDescription)"
                return nil
            }
        }
    }

    func finishRecordingPipelineAdmission(taskID: UUID, meetingID: UUID, saved: Bool) async {
        let committed =
            saved
            ? await enqueueCanonical {
                guard let index = self.meetings.firstIndex(where: { $0.id == meetingID }) else { return false }
                self.meetings[index].completedTaskIDs[BackgroundJob.Kind.recordingFinalization.rawValue] = taskID
                return await self.performCanonicalSave()
            } : false
        await completeManagedTask(
            taskID, state: committed ? .completed : .failed,
            recovery: committed ? .none : .blocked,
            message: committed
                ? nil : "The recording could not be fully saved. Review its saved audio before processing.")
    }

    func pipelineDependencyRecords(_ task: ManagedTaskRecord) async throws -> [ManagedTaskRecord] {
        let ids = task.dependencyIDs ?? []
        guard !ids.isEmpty else { return [] }
        let journal = managedTaskJournal
        let predicate = ids.map { ManagedTaskIndex.literal($0.uuidString) }.joined(separator: ",")
        return try await managedTaskIO.perform {
            let values = try journal.query(where: "id IN (" + predicate + ")", limit: ids.count)
            guard values.count == ids.count else { throw ServiceError("A processing dependency is missing.") }
            return values
        }
    }

    func runnableManagedTasks(kind: BackgroundJob.Kind, limit: Int, excluding: String) async throws
        -> [ManagedTaskRecord]
    {
        let journal = managedTaskJournal
        let occupied = Set(backgroundJobs.filter { $0.key.kind == kind }.compactMap(\.meetingID))
        return try await managedTaskIO.perform {
            var selected: [ManagedTaskRecord] = []
            var occupiedMeetings = occupied
            var cursor = ""
            while selected.count < limit {
                let page = try journal.query(
                    where: "kind=" + ManagedTaskIndex.literal(kind.rawValue)
                        + " AND state='queued'" + excluding + cursor, order: "priority DESC,created,id", limit: 50)
                for candidate in page where !occupiedMeetings.contains(candidate.meetingID) {
                    let ids = candidate.dependencyIDs ?? []
                    let dependencies =
                        ids.isEmpty
                        ? []
                        : try journal.query(
                            where: "id IN ("
                                + ids.map { ManagedTaskIndex.literal($0.uuidString) }.joined(separator: ",") + ")",
                            limit: ids.count)
                    // Missing dependencies reach the worker and become a visible failure.
                    if dependencies.allSatisfy(RecordingPipeline.isSettled) {
                        selected.append(candidate)
                        occupiedMeetings.insert(candidate.meetingID)
                        if selected.count == limit { return selected }
                    }
                }
                guard page.count == 50, let last = page.last else { return selected }
                let date = last.createdAt.timeIntervalSince1970
                cursor =
                    " AND (priority<\(last.queuePriority) OR (priority=\(last.queuePriority) AND (created>\(date)"
                    + " OR (created=\(date) AND id>\(ManagedTaskIndex.literal(last.id.uuidString))))))"
            }
            return selected
        }
    }

    /// Read durable rows, including dependencies that have left the bounded UI cache.
    func pipelineDependenciesReady(_ task: ManagedTaskRecord) async throws -> Bool {
        let dependencies = try await pipelineDependencyRecords(task)
        return dependencies.allSatisfy(RecordingPipeline.isSettled)
    }

    func pipelineNoDataReason(_ task: ManagedTaskRecord, meeting: Meeting) async throws -> String? {
        guard task.pipelineID != nil else { return nil }
        let dependencies = try await pipelineDependencyRecords(task)
        if dependencies.contains(where: { $0.kind == .recordingFinalization && $0.state != .completed }) {
            return "Skipped because the recording could not be fully saved."
        }
        switch task.kind {
        case .transcription:
            if task.preferFinalizedLiveTranscript == true && meeting.liveTranscriptAdopted
                && meeting.transcript.contains(where: {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            {
                return "Using the finalized live transcript."
            }
            if meeting.audioFiles.isEmpty { return "There is no saved audio to transcribe." }
        case .diarization:
            if meeting.audioFiles.isEmpty { return "There is no saved audio to diarize." }
            if meeting.transcript.isEmpty { return "There is no transcript to label." }
            if meeting.transcriptionAttempt != nil {
                return "The pending transcription needs review before speaker labeling."
            }
        case .speakerAssociation:
            if meeting.speakers.isEmpty { return "There are no speakers to associate with People." }
        case .summary:
            if try SummaryHistory.generation(taskID: task.id, at: directory(for: meeting.id)) != nil { return nil }
            if meeting.transcript.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                && meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "There is no transcript or notes to summarize."
            }
        case .todoExtraction:
            if let summary = dependencies.first(where: { $0.kind == .summary }),
                summary.pipelineOutcome != .disabled,
                summary.state != .completed || summary.pipelineOutcome == .noData
            {
                return "There is no generated summary to extract to-dos from."
            }
            if meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "There is no saved summary to extract to-dos from."
            }
        default: break
        }
        return nil
    }

    func performPipelineSpeakerAssociation(id: UUID) async throws {
        setJobProgress(.speakerAssociation, .meeting(id), "Preparing speaker examples…")
        await voiceLibrary.awaitLoaded()
        guard let meeting = meeting(id: id) else { throw MissingManagedTaskMeeting() }
        guard voiceLibrary.ingest(meeting: meeting, directory: directory(for: id)) else {
            throw ServiceError(voiceLibrary.errorMessage ?? "Couldn’t prepare speaker examples.")
        }
        setJobProgress(.speakerAssociation, .meeting(id), "Comparing voices with the People Library…")
        try await voiceLibrary.suggestReviewedPeopleResult(from: people)
        try Task.checkCancellation()
        setJobProgress(.speakerAssociation, .meeting(id), "Saving speaker associations…")
        let saved = await enqueueCanonical {
            guard let index = self.meetings.firstIndex(where: { $0.id == id }) else { return false }
            var current = self.voiceLibrary.applyingDecisions(to: self.meetings[index])
            self.markManagedTaskCompletion(on: &current, kind: .speakerAssociation)
            self.meetings[index] = current
            return await self.performCanonicalSave()
        }
        guard saved else { throw ServiceError(errorMessage ?? "Couldn’t save speaker associations.") }
    }

    /// A failed summary has no derived output. Its successful retry releases the
    /// same extraction stage; completed extractions are never replayed here.
    func resumePipelineTodoAfterSummary(_ summary: ManagedTaskRecord) async {
        guard let run = summary.pipelineID, summary.kind == .summary,
            (try? hasCompletedSummary(taskID: summary.id, meetingID: summary.meetingID)) == true
        else { return }
        let journal = managedTaskJournal
        do {
            let tasks = try await managedTaskIO.perform {
                try journal.query(
                    where: "meeting=" + ManagedTaskIndex.literal(summary.meetingID.uuidString)
                        + " AND kind='todoExtraction'", limit: Int.max)
            }
            for var task in tasks
            where task.pipelineID == run && task.state == .completed && task.pipelineOutcome == .noSummaryResult {
                task.state = .queued
                task.pipelineOutcome = nil
                task.recovery = .automatic
                task.finishedAt = nil
                task.errorMessage = nil
                task.progress = "Waiting to extract to-dos"
                guard await saveManagedTask(task) else { return }
            }
        }
        catch { managedTaskJournalError = "Couldn’t resume to-do extraction. \(error.localizedDescription)" }
    }

    func performPipelineTodoExtraction(_ task: ManagedTaskRecord) async throws {
        setJobProgress(.todoExtraction, .meeting(task.meetingID), "Reading the saved summary…")
        let summaryTask = try await pipelineDependencyRecords(task).first { $0.kind == .summary }
        let generated = try summaryTask.flatMap { dependency in
            dependency.pipelineOutcome == .completed
                ? try SummaryHistory.generation(taskID: dependency.id, at: directory(for: task.meetingID))?.result
                : nil
        }
        setJobProgress(.todoExtraction, .meeting(task.meetingID), "Extracting and saving to-dos…")
        let saved = await enqueueCanonical {
            guard let index = self.meetings.firstIndex(where: { $0.id == task.meetingID }) else { return false }
            var current = self.meetings[index]
            let known = Set(current.todos.map { $0.title.lowercased() })
            current.todos += Self.actionItems(from: generated ?? current.summary).filter {
                !known.contains($0.title.lowercased())
            }
            current.completedTaskIDs[BackgroundJob.Kind.todoExtraction.rawValue] = task.id
            self.meetings[index] = current
            return await self.performCanonicalSave()
        }
        guard saved else { throw ServiceError(errorMessage ?? "Couldn’t save extracted to-dos.") }
    }
}
