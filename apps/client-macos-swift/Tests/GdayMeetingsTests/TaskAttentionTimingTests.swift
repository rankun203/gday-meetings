import Combine
import Foundation
import Testing

@testable import GdayMeetings

struct TaskAttentionTimingTests {
    @Test func executionStateAndAttentionAreIndependent() {
        var task = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic meeting", state: .failed)
        #expect(!task.needsAttention)
        task.recovery = .manual
        task.errorMessage = "The provider connection was interrupted."
        #expect(task.needsAttention)
        #expect(TaskHistoryScope.attention.includes(task))
        task.attentionAcknowledged = true
        #expect(task.state == .failed)
        #expect(!TaskHistoryScope.attention.includes(task))
        #expect(TaskDescription(.managed(task)).progress == task.errorMessage)
        task.state = .paused
        task.errorMessage = "The saved input changed."
        task.attentionAcknowledged = false
        #expect(task.attentionReason == .externalChange)
    }

    @Test func acknowledgedVoiceFailureRetainsProblemSummary() {
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: true, exampleIDs: [])
        job.state = .failed
        job.failures = ["recording-\(UUID())": "The recording has no audio."]
        job.attentionAcknowledged = true
        #expect(!job.needsAttention)
        #expect(TaskDescription(.voice(job)).progress == "1 failed item")
    }

    @Test func timingKeepsRemoteWaitAndRetriesSeparateFromLocalWork() {
        let origin = Date(timeIntervalSince1970: 100)
        let events: [TaskAttemptEvent] = [
            .init(kind: .queued, date: origin, reason: nil),
            .init(kind: .started, date: origin.addingTimeInterval(10), reason: nil),
            .init(kind: .waitingForProvider, date: origin.addingTimeInterval(15), reason: nil),
            .init(kind: .ended, date: origin.addingTimeInterval(100), reason: "Connection interrupted."),
            .init(kind: .queued, date: origin.addingTimeInterval(200), reason: nil),
            .init(kind: .resumed, date: origin.addingTimeInterval(220), reason: nil),
            .init(kind: .ended, date: origin.addingTimeInterval(250), reason: nil),
        ]
        let timing = TaskTiming.measure(events, now: origin.addingTimeInterval(500))
        #expect(timing.active == 35)
        #expect(timing.waiting == 115)
    }

    @Test func voicePauseAndRetryRetainHistoryAndReasons() {
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: true, exampleIDs: [])
        let queued = job
        job.state = .running
        job.recordTransition(from: queued)
        let running = job
        job.state = .paused
        job.recordTransition(from: running)
        #expect(job.timeline?.last?.reason == "Pause requested")
        let paused = job
        job.state = .running
        job.recordTransition(from: paused)
        #expect(job.timeline?.last?.kind == .resumed)
        #expect(job.timeline?.last?.reason == "Resume requested")
        let resumed = job
        job.state = .cancelled
        job.recordTransition(from: resumed)
        let cancelled = job
        job.state = .running
        job.recordTransition(from: cancelled)
        #expect(job.timeline?.count == 5)
        #expect(job.timeline?.last?.reason == "Retry requested")
    }

    @Test func journalRewritesCompareTaskContentRatherThanEventOffsets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tasks.jsonl")
        let journal = ManagedTaskJournal(url: url)
        let task = ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic meeting")
        try journal.upsert(task)
        let rewriteURL = root.appendingPathComponent("rewrite.jsonl")
        let rewrite = ManagedTaskJournal(url: rewriteURL, indexURL: root.appendingPathComponent("rewrite.sqlite"))
        try rewrite.upsert(
            ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic history", state: .completed))
        try rewrite.upsert(task)
        try Data(contentsOf: rewriteURL).write(to: url)
        try journal.prepare()
        #expect(try !journal.changedSinceRebuild(task.id))
        var changed = task
        changed.providerID = UUID()
        let external = ManagedTaskJournal(url: url, indexURL: root.appendingPathComponent("external.sqlite"))
        try external.upsert(changed)
        try journal.prepare()
        #expect(try journal.changedSinceRebuild(task.id))
    }

    @Test @MainActor func dismissAlertKeepsSavedIntentAndRecoveryData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let record = ManagedTaskRecord(
            kind: .transcription, meetingID: UUID(), meetingTitle: "Synthetic meeting", state: .failed,
            recovery: .restartRequired, attemptKey: "synthetic-request", remoteJobID: "synthetic-job")
        try store.managedTaskJournal.upsert(record)
        try await store.restoreManagedTasks()
        #expect(store.taskAttentionCount == 1)
        await store.dismissManagedTaskAlert(id: record.id)
        let saved = try #require(store.managedTaskJournal.record(id: record.id))
        #expect(saved.state == .failed)
        #expect(saved.attemptKey == "synthetic-request")
        #expect(saved.remoteJobID == "synthetic-job")
        #expect(saved.recovery == .restartRequired)
        #expect(!saved.dismissRequested)
        #expect(store.taskAttentionCount == 0)
        #expect(await store.taskHistoryPage(scope: .attention).isEmpty)
    }
}

extension TaskAttentionTimingTests {
    @Test @MainActor func progressCoalescesAndEndingAJobDropsPendingUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        #expect(store.beginJob(.archive, .library, progress: "Starting"))
        for index in 0..<1_000 { store.setJobProgress(.archive, .library, "Item \(index)") }
        #expect(store.backgroundJobs.first?.progress == "Item 0")
        await store.jobProgressFlush?.value
        #expect(store.backgroundJobs.first?.progress == "Item 999")
        #expect(store.pendingJobProgress.isEmpty)
        store.setJobProgress(.archive, .library, "Pending")
        store.endJob(.archive, .library)
        await store.jobProgressFlush?.value
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.pendingJobProgress.isEmpty)
    }
}

extension TaskAttentionTimingTests {
    @Test func legacyRetryStartsMeasuredHistoryAtObservedTransition() {
        let old = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic meeting",
            state: .failed, createdAt: Date(timeIntervalSince1970: 10), recovery: .manual)
        var resumed = old
        resumed.state = .queued
        let observed = Date(timeIntervalSince1970: 1_000)
        resumed.recordTransition(from: old, now: observed)
        let timing = TaskTiming.measure(resumed.timeline ?? [], now: observed.addingTimeInterval(5))
        #expect(timing.waiting == 5)
        #expect(timing.active == 0)
        #expect(resumed.timeline?.first?.date == observed)
    }

    @Test func manualIndexTasksStayInOrdinaryTaskScopes() {
        var task = ManagedTaskRecord(kind: .searchIndex, meetingID: UUID(), meetingTitle: "Synthetic meeting")
        #expect(TaskHistoryScope.all.includes(task))
        #expect(TaskHistoryScope.active.includes(task))
        #expect(!TaskHistoryScope.maintenance.includes(task))
        task.isAutomatic = true
        #expect(!TaskHistoryScope.all.includes(task))
        #expect(TaskHistoryScope.maintenance.includes(task))
        task.state = .failed
        task.recovery = .manual
        #expect(TaskHistoryScope.attention.includes(task))
        #expect(TaskHistoryScope.all.includes(task))
    }
}

extension TaskAttentionTimingTests {
    @Test @MainActor func recordingBeginningAtDurableStartReturnsSpeakerTaskToQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let meetingID = await store.createMeeting(title: "Synthetic meeting")
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        var recordingBegan = false
        let observation = store.$managedTasks.sink { tasks in
            if tasks.contains(where: { $0.kind == .diarization && $0.state == .running }) {
                recordingBegan = true
                store.recordingID = UUID()
            }
        }
        let id = try #require(await store.queueSpeakerLabelingCommand(id: meetingID))
        observation.cancel()
        #expect(recordingBegan)
        #expect(store.managedTask(id: id)?.state == .queued)
        #expect(store.managedTaskOperations.isEmpty)
        await store.cancelManagedTask(id: id)
        store.recordingID = nil
    }

    @Test @MainActor func speakerLabelingWaitsInQueueDuringRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let meetingID = await store.createMeeting(title: "Synthetic meeting")
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.recordingID = UUID()
        let id = try #require(await store.queueSpeakerLabelingCommand(id: meetingID))
        let task = try #require(store.managedTask(id: id))
        #expect(task.state == .queued)
        #expect(task.progress == "Waiting for recording to finish")
        #expect(store.managedTaskOperations.isEmpty)
        await store.cancelManagedTask(id: id)
        store.recordingID = nil
    }

    @Test @MainActor func explicitIndexRequestRemainsQueuedDuringRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let meetingID = await store.createMeeting(title: "Synthetic meeting")
        let provider = ServiceProvider(kind: .localSearch)
        store.settings.serviceProviders = [provider]
        store.settings.searchProviderID = provider.id
        store.recordingID = UUID()
        #expect(await store.queueSearchIndexCommand(id: meetingID, revision: "synthetic-source", force: false) == nil)
        let id = try #require(
            await store.queueSearchIndexCommand(id: meetingID, revision: "synthetic-source", force: true))
        let task = try #require(store.managedTask(id: id))
        #expect(task.state == .queued)
        #expect(!task.isAutomatic)
        #expect(task.progress == "Waiting for recording to finish")
        #expect(store.managedTaskOperations.isEmpty)
        #expect(await store.taskHistoryPage(scope: .active).contains { $0.id == id })
        await store.cancelManagedTask(id: id)
        store.recordingID = nil
    }
}
