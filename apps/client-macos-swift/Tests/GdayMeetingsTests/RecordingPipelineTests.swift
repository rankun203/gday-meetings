import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingPipelineTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func disabledStagesStillWaitForTheirTransitiveDependencies() throws {
        var settings = AppSettings()
        settings.autoTranscribe = true
        settings.labelRecordedSpeakers = false
        settings.recognizeSpeakers = true
        settings.autoSummarize = true
        let tasks = RecordingPipeline.tasks(meeting: Meeting(), settings: settings, transcribeAfter: true)
        let transcript = try #require(tasks.first { $0.kind == .transcription })
        let labels = try #require(tasks.first { $0.kind == .diarization })
        let association = try #require(tasks.first { $0.kind == .speakerAssociation })
        #expect(labels.state == .queued)
        #expect(labels.pipelineOutcome == .disabled)
        #expect(labels.dependencyIDs?.contains(transcript.id) == true)
        #expect(association.dependencyIDs?.contains(labels.id) == true)
        #expect(!RecordingPipeline.isSettled(labels))
    }

    @Test func automaticRecoveryIsNotASettledDependency() {
        var task = ManagedTaskRecord(kind: .transcription, meetingID: UUID(), meetingTitle: "Fixture")
        task.state = .failed
        task.recovery = .automatic
        #expect(!RecordingPipeline.isSettled(task))
        task.recovery = .manual
        #expect(RecordingPipeline.isSettled(task))
    }

    @Test func batchReplayKeepsTheWholeGraphAndDiscardsATornNextBatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl"))
        let tasks = RecordingPipeline.tasks(meeting: Meeting(), settings: AppSettings(), transcribeAfter: true)
        try journal.upsertBatch(tasks)
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"operation\":\"batch\"".utf8))
        try handle.close()
        let reopened = ManagedTaskJournal(url: journal.url)
        #expect(Set(try reopened.load().map(\.id)) == Set(tasks.map(\.id)))
        var completed = tasks[0]
        completed.state = .completed
        try reopened.upsert(completed)
        #expect(try reopened.query(limit: 20).count == tasks.count)
    }

    @Test func schedulerLooksBeyondBlockedPagesAndReadsUncachedDependencies() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let meetingID = UUID()
        let blocker = ManagedTaskRecord(kind: .transcription, meetingID: meetingID, meetingTitle: "Fixture")
        var tasks = [blocker]
        for index in 0..<60 {
            var task = ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "Fixture")
            task.createdAt = Date(timeIntervalSince1970: Double(index))
            task.dependencyIDs = [blocker.id]
            tasks.append(task)
        }
        var ready = ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "Ready")
        ready.createdAt = Date(timeIntervalSince1970: 100)
        tasks.append(ready)
        let batch = tasks
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsertBatch(batch) }
        store.managedTasks = []
        let selected = try await store.runnableManagedTasks(kind: .summary, limit: 1, excluding: "")
        #expect(selected.map(\.id) == [ready.id])
    }

    @Test func noSummaryFinishesTodoWithoutAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoTranscribe = false
        store.settings.labelRecordedSpeakers = false
        store.settings.recognizeSpeakers = false
        store.settings.autoSummarize = false
        store.settings.autoExtractTodos = true
        let id = await store.createMeeting(title: "Empty fixture")
        let rootTask = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: true))
        await store.finishRecordingPipelineAdmission(taskID: rootTask, meetingID: id, saved: true)
        let finished = try await waitForMainActorTestCondition {
            store.managedTasks.contains { $0.kind == .todoExtraction && $0.state == .completed }
        }
        #expect(finished)
        let task = try #require(store.managedTasks.first { $0.kind == .todoExtraction })
        #expect(task.pipelineOutcome == .noData)
        #expect(!task.needsAttention)
        #expect(task.progress.contains("no saved summary"))
    }

    @Test func existingSummarySuppliesTodosWhenAutomaticSummaryIsDisabled() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoTranscribe = false
        store.settings.labelRecordedSpeakers = false
        store.settings.recognizeSpeakers = false
        store.settings.autoSummarize = false
        store.settings.autoExtractTodos = true
        let id = await store.createMeeting(title: "Saved summary fixture")
        var meeting = try #require(store.meeting(id: id))
        meeting.summary = "- [ ] Review the draft"
        #expect(await store.updateMeeting(meeting))
        let rootTask = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: true))
        #expect(await store.admitRecordingPipeline(id: id, transcribeAfter: true) == rootTask)
        await store.finishRecordingPipelineAdmission(taskID: rootTask, meetingID: id, saved: true)
        let finished = try await waitForMainActorTestCondition {
            store.managedTasks.contains { $0.kind == .todoExtraction && $0.state == .completed }
        }
        #expect(finished)
        #expect(store.meeting(id: id)?.todos.map(\.title) == ["Review the draft"])
    }
    @Test(arguments: [false, true]) func stopPublishesLiveTextWithoutItsOwnQueuedTaskBlockingAdoption(hasText: Bool)
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoTranscribe = true
        store.settings.labelRecordedSpeakers = false
        store.settings.recognizeSpeakers = false
        store.settings.autoSummarize = false
        store.settings.autoExtractTodos = false
        let id = await store.createMeeting(title: "Synthetic capture")
        store.recordingID = id
        store.liveTranscript.begin(
            meetingID: id, language: "en", directory: store.directory(for: id),
            sources: [.microphone], sink: LiveAudioSink(), enabled: false)
        if hasText {
            let token = UUID()
            store.liveTranscript.finalizeDetachedSession(
                token: token,
                work: {
                    store.liveTranscript.receive(
                        .init(
                            session: UUID(), source: .microphone, start: 1, end: 2,
                            text: "A synthetic sentence."), final: true, token: token)
                    return true
                }, cancel: nil)
        }
        await store.stopRecording()
        let saved = try #require(store.managedTasks.first { $0.kind == .recordingFinalization })
        #expect(saved.state == .completed)
        #expect(store.meeting(id: id)?.liveTranscriptAdopted == hasText)
        if hasText { #expect(store.meeting(id: id)?.transcript.first?.text == "A synthetic sentence.") }
        let settled = try await waitForMainActorTestCondition {
            !store.managedTasks.contains { $0.pipelineID == saved.pipelineID && $0.state.isActive }
        }
        #expect(settled)
    }

    @Test(arguments: [false, true]) func restartUsesFinalizationReceiptAndDoesNotAssumeUncommittedAudioIsReady(
        receipt: Bool
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoTranscribe = false
        store.settings.labelRecordedSpeakers = false
        store.settings.recognizeSpeakers = false
        store.settings.autoSummarize = false
        store.settings.autoExtractTodos = true
        let id = await store.createMeeting(title: "Interrupted capture fixture")
        let taskID = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: false))
        if receipt {
            var meeting = try #require(store.meeting(id: id))
            meeting.completedTaskIDs[BackgroundJob.Kind.recordingFinalization.rawValue] = taskID
            #expect(await store.updateMeeting(meeting))
        }
        let reopened = MeetingStore(dataDirectory: root)
        await reopened.managedTaskPreparation?.value
        let settled = try await waitForMainActorTestCondition {
            reopened.managedTasks.contains { $0.kind == .todoExtraction && $0.state == .completed }
        }
        #expect(settled)
        let saved = try #require(reopened.managedTasks.first { $0.id == taskID })
        #expect(saved.state == (receipt ? .completed : .failed))
        #expect(saved.needsAttention == !receipt)
        let extraction = try #require(reopened.managedTasks.first { $0.kind == .todoExtraction })
        #expect(extraction.pipelineOutcome == .noData)
        #expect(!extraction.needsAttention)
    }

    @Test func finalizationCannotBeCancelledOrDiscardedWhileSaving() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Saving fixture")
        store.recordingID = id
        store.isFinalizingRecording = true
        let taskID = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: false))
        await store.cancelManagedTask(id: taskID)
        await store.removeManagedTask(id: taskID)
        #expect(store.managedTask(id: taskID)?.state == .running)
        #expect(!store.managedTaskStopRequests.contains(taskID))
        store.isFinalizingRecording = false
        store.recordingID = nil
        await store.finishRecordingPipelineAdmission(taskID: taskID, meetingID: id, saved: false)
    }

    @Test func discardedStageRetainsItsDependencyIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoSummarize = false
        let id = await store.createMeeting(title: "Discard fixture")
        let rootTask = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: false))
        let labels = try #require(store.managedTasks.first { $0.kind == .diarization })
        await store.removeManagedTask(id: labels.id)
        let journal = store.managedTaskJournal
        let discarded = try await store.managedTaskIO.perform {
            try journal.query(where: "id=" + ManagedTaskIndex.literal(labels.id.uuidString), limit: 1).first
        }
        #expect(discarded?.state == .cancelled)
        #expect(discarded?.recovery == ManagedTaskRecovery.none)
        await store.finishRecordingPipelineAdmission(taskID: rootTask, meetingID: id, saved: true)
        let settled = try await waitForMainActorTestCondition {
            !store.managedTasks.contains { $0.pipelineID == labels.pipelineID && $0.state.isActive }
        }
        #expect(settled)
        #expect(!store.managedTasks.contains { $0.errorMessage?.contains("dependency is missing") == true })
    }

    @Test func successfulSummaryRetryReleasesTheSameExtractionStage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = PipelineResponseCounter()
        let server = try HTTPFixture { _ in
            if counter.next() == 1 { return .init(status: 500, body: "{}") }
            return .init(body: #"{"choices":[{"message":{"content":"- [ ] Review the new draft"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture-model"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        store.settings.autoTranscribe = false
        store.settings.labelRecordedSpeakers = false
        store.settings.recognizeSpeakers = false
        store.settings.autoSummarize = true
        store.settings.autoExtractTodos = true
        let id = await store.createMeeting(title: "Retry fixture")
        var meeting = try #require(store.meeting(id: id))
        meeting.notes = "The draft needs review."
        meeting.summary = "- [ ] Review the previous draft"
        #expect(await store.updateMeeting(meeting))
        let saved = try #require(await store.admitRecordingPipeline(id: id, transcribeAfter: false))
        await store.finishRecordingPipelineAdmission(taskID: saved, meetingID: id, saved: true)
        let initial = try await waitForMainActorTestCondition {
            store.managedTasks.contains { $0.kind == .todoExtraction && $0.pipelineOutcome == .noSummaryResult }
        }
        #expect(initial)
        #expect(store.meeting(id: id)?.todos.isEmpty == true)
        let summary = try #require(store.managedTasks.first { $0.kind == .summary })
        let extraction = try #require(store.managedTasks.first { $0.kind == .todoExtraction })
        #expect(summary.state == .failed)
        await store.retryManagedTask(id: summary.id)
        let retried = try await waitForMainActorTestCondition {
            store.managedTask(id: extraction.id)?.pipelineOutcome == .completed
        }
        #expect(retried)
        #expect(store.meeting(id: id)?.todos.map(\.title) == ["Review the new draft"])
        #expect(store.managedTasks.filter { $0.kind == .todoExtraction }.count == 1)
        #expect(counter.count == 2)
    }

}

private final class PipelineResponseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
