import Foundation
import Testing

@testable import GdayMeetings

private final class SpeakerBindingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var entered = false
    var isWaiting: Bool { lock.withLock { entered } }
    func waitOnce() {
        let first = lock.withLock {
            guard !entered else { return false }
            entered = true
            return true
        }
        if first { signal.wait() }
    }
    func resume() { signal.signal() }
}

@MainActor struct SpeakerTaskTests {
    @Test(arguments: [false, true])
    func durableLabelBindingRevalidatesInputsAndKeepsUnrelatedEdits(changedTranscript: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var original = Meeting(title: "Labeling fixture")
        original.notes = "Original notes"
        original.transcript = [.init(start: 0, end: 1, text: "Original transcript")]
        try await store.insertImportedMeeting(original)
        let record = ManagedTaskRecord(
            kind: .diarization, meetingID: original.id,
            meetingTitle: original.title, state: .running)
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(record) }
        try await store.restoreManagedTasks()
        store.isSchedulingManagedTasks = true
        let gate = SpeakerBindingGate()
        defer { gate.resume() }
        store.managedTaskIO = ManagedTaskIO { gate.waitOnce() }
        let resultID = UUID()
        let applying = Task {
            try await store.validatedMeetingForSpeakerLabeling(
                resultID: resultID, original: original, files: [], sourceRevisions: [:])
        }
        let waiting = try await waitForMainActorTestCondition { gate.isWaiting }
        guard waiting else {
            gate.resume()
            Issue.record("Label binding did not reach the storage gate")
            return
        }
        var edited = try #require(store.meeting(id: original.id))
        edited.title = "Edited title"
        edited.notes = "Edited notes"
        if changedTranscript { edited.transcript[0].text = "Edited transcript" }
        #expect(await store.updateMeeting(edited))
        gate.resume()
        if changedTranscript {
            await #expect(throws: (any Error).self) { try await applying.value }
        }
        else {
            let current = try await applying.value
            #expect(current.title == edited.title)
            #expect(current.notes == edited.notes)
            #expect(current.transcript == original.transcript)
        }
        #expect(store.meeting(id: original.id) == edited)
        #expect(store.managedTask(id: record.id)?.speakerLabelingResultID == resultID)
        await store.flushManagedTaskCommands()
    }

    @Test func samePathReplacementInvalidatesLabelingInputSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("synthetic.wav")
        try Data([1, 2, 3]).write(to: audio)
        let before = try LocalDiarizationInputPolicy.revisions(for: [audio])
        #expect(try LocalDiarizationInputPolicy.revisions(for: [audio]) == before)
        try Data([4, 5, 6, 7]).write(to: audio, options: .atomic)
        #expect(try LocalDiarizationInputPolicy.revisions(for: [audio]) != before)
        try FileManager.default.removeItem(at: audio)
        #expect(throws: (any Error).self) { try LocalDiarizationInputPolicy.revisions(for: [audio]) }
    }

    @Test func missingAudioFailureIsPersistedAndAwaited() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let meeting = Meeting(title: "Synthetic speaker task")
        try await store.insertImportedMeeting(meeting)
        let provider = ServiceProvider(kind: .community1)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        await store.diarizeLocally(id: meeting.id)
        let task = try #require(store.managedTasks.first)
        #expect(task.kind == .diarization && task.state == .failed)
        #expect(task.errorMessage == "This meeting has no local audio to label.")
        #expect(task.providerID == provider.id && task.recovery == .manual)
        #expect(!store.isJobRunning(.diarization, .meeting(meeting.id)))
        #expect(try store.managedTaskJournal.load().first?.state == .failed)
        #expect(store.canRetryManagedTask(task))
    }

    @Test func queuedLabelingCanBeCancelledWithoutStartingInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let meeting = Meeting(title: "Synthetic queued labels")
        try await store.insertImportedMeeting(meeting)
        let provider = ServiceProvider(kind: .community1)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.isSchedulingManagedTasks = true
        let taskID = try #require(await store.queueSpeakerLabeling(id: meeting.id))
        #expect(store.managedTasks.first?.state == .queued)
        await store.cancelLocalDiarization(id: meeting.id)
        #expect(store.managedTasks.first?.id == taskID)
        #expect(store.managedTasks.first?.state == .cancelled)
        #expect(store.managedTaskOperations.isEmpty && store.backgroundJobs.isEmpty)
        #expect(try store.managedTaskJournal.load().first?.state == .cancelled)
    }

    @Test func interruptedLabelingRequiresExplicitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let meeting = Meeting(title: "Synthetic interruption")
        try await store.insertImportedMeeting(meeting)
        var task = ManagedTaskRecord(kind: .diarization, meetingID: meeting.id, meetingTitle: meeting.title)
        task.state = .running
        try store.managedTaskJournal.upsert(task)
        try await store.restoreManagedTasks()
        await store.recoverUnfinishedManagedTasks()
        let restored = try #require(store.managedTasks.first)
        #expect(restored.state == .failed && restored.recovery == .manual)
        #expect(restored.errorMessage?.contains("interrupted") == true)
        #expect(store.managedTaskOperations.isEmpty && store.backgroundJobs.isEmpty)
    }

    @Test func persistedVoiceJobsCountOnceAndRecoverPausedAtLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1, discover: true, exampleIDs: [])
        job.state = .running
        _ = store.voiceLibrary.setJobs([job])
        #expect(store.taskQueueActivitySummary == "1 running")
        #expect(store.taskQueueOtherJobs.isEmpty)
        job.state = .failed
        _ = store.voiceLibrary.setJobs([job])
        #expect(store.taskAttentionCount == 1)
        #expect(store.showsTaskQueueStatus)
        job.state = .running
        #expect(store.voiceLibrary.setJobs([job]))
        let reopened = MeetingStore(dataDirectory: root)
        #expect(reopened.voiceLibrary.jobs.first?.state == .paused)
        #expect(reopened.taskQueueActivitySummary.isEmpty)

    }
}
