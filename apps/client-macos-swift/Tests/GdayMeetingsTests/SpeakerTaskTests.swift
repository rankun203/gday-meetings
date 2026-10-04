import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SpeakerTaskTests {
    @Test func samePathReplacementInvalidatesLabelingInputSnapshot() throws {
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
        try store.insertImportedMeeting(meeting)
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

    @Test func queuedLabelingCanBeCancelledWithoutStartingInference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let meeting = Meeting(title: "Synthetic queued labels")
        try store.insertImportedMeeting(meeting)
        let provider = ServiceProvider(kind: .community1)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.isSchedulingManagedTasks = true
        let taskID = try #require(store.queueSpeakerLabeling(id: meeting.id))
        #expect(store.managedTasks.first?.state == .queued)
        store.cancelLocalDiarization(id: meeting.id)
        #expect(store.managedTasks.first?.id == taskID)
        #expect(store.managedTasks.first?.state == .cancelled)
        #expect(store.managedTaskOperations.isEmpty && store.backgroundJobs.isEmpty)
        #expect(try store.managedTaskJournal.load().first?.state == .cancelled)
    }

    @Test func interruptedLabelingRequiresExplicitRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let meeting = Meeting(title: "Synthetic interruption")
        try store.insertImportedMeeting(meeting)
        var task = ManagedTaskRecord(kind: .diarization, meetingID: meeting.id, meetingTitle: meeting.title)
        task.state = .running
        try store.managedTaskJournal.upsert(task)
        try store.restoreManagedTasks()
        store.recoverUnfinishedManagedTasks()
        let restored = try #require(store.managedTasks.first)
        #expect(restored.state == .failed && restored.recovery == .manual)
        #expect(restored.errorMessage?.contains("interrupted") == true)
        #expect(store.managedTaskOperations.isEmpty && store.backgroundJobs.isEmpty)
    }

    @Test func persistedVoiceJobsCountOnceAndRecoverPausedAtLaunch() throws {
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
