import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SpeakerConsolidationSchedulingTests {
    private func fixture(root: URL, trusted: Bool = true, model: EmbeddingType = .community1SpeechSpan) async throws
        -> (MeetingStore, Meeting, URL)
    {
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        store.settings.recognizeSpeakers = false
        store.settings.serviceProviders = []
        store.isSchedulingManagedTasks = true
        var meeting = Meeting(title: "Synthetic scheduling")
        meeting.audioFiles = ["microphone.wav"]
        meeting.transcript = [.init(start: 0, end: 3, text: "Synthetic speech.", source: .microphone)]
        let directory = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("microphone.wav")
        try Data([0, 1, 2, 3]).write(to: audio)
        try await store.insertImportedMeeting(meeting)
        let evidence = SpeakerEvidenceStore(directory: directory)
        try await evidence.append(
            SpeakerEvidenceSample(
                id: "sample-a", source: "microphone",
                localSpeakerID: "local-a", start: 0, end: 3,
                embedding: .init(type: model, values: [1] + [Double](repeating: 0, count: 255))))
        try await evidence.append(
            [
                SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "local-a", start: 0, end: 3)
            ],
            window: trusted
                ? .init(
                    generation: "window-a", source: "microphone", localSpeakerIDs: ["local-a"],
                    publicationStart: 0, observedEnd: 3, policyRevision: SpeakerEvidenceWindow.protectedPolicy) : nil)
        try await evidence.finish()
        try SpeakerEvidenceInputReceipt.seal(directory: directory, files: [audio])
        return (store, meeting, audio)
    }

    @Test func legacyOrUnsupportedEvidenceDoesNotScheduleConsolidation() async throws {
        for (trusted, model) in [(false, EmbeddingType.community1SpeechSpan), (true, .community1)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (store, meeting, _) = try await fixture(root: root, trusted: trusted, model: model)
            store.settings.labelRecordedSpeakers = true
            await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
            #expect(store.managedTasks.filter { $0.kind == .diarization }.isEmpty)
        }
    }

    @Test func automaticConsolidationHonorsSettingAndNeedsNoInferenceProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        store.settings.labelRecordedSpeakers = false
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTasks.filter { $0.kind == .diarization }.isEmpty)
        store.settings.labelRecordedSpeakers = true
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let task = try #require(store.managedTasks.first { $0.kind == .diarization })
        #expect(task.state == .queued)
        #expect(task.isAutomatic)
        #expect(task.consolidatesRetainedVoiceEvidence == true)
        #expect(task.providerID == ThisMacProvider.id)
        await store.cancelLocalDiarization(id: meeting.id)
    }

    @Test func automaticConsolidationRejectsReplacedAudioAndDoesNotReviveCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, audio) = try await fixture(root: root)
        store.settings.labelRecordedSpeakers = true
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let task = try #require(store.managedTasks.first { $0.kind == .diarization })
        await store.cancelLocalDiarization(id: meeting.id)
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTasks.first { $0.id == task.id }?.state == .cancelled)
        #expect(store.managedTasks.filter { $0.kind == .diarization }.count == 1)
        try Data([4, 5, 6, 7]).write(to: audio, options: .atomic)
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTasks.first { $0.id == task.id }?.state == .cancelled)
        #expect(store.managedTasks.filter { $0.kind == .diarization }.count == 1)
    }

    @Test func changedAudioDoesNotScheduleAnAutomaticTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, audio) = try await fixture(root: root)
        store.settings.labelRecordedSpeakers = true
        try Data([4, 5, 6, 7]).write(to: audio, options: .atomic)
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTasks.filter { $0.kind == .diarization }.isEmpty)
    }

    @Test func queuedAutomaticTaskHonorsSettingAfterRecordingDeferral() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        store.settings.labelRecordedSpeakers = true
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let taskID = try #require(store.managedTasks.first { $0.kind == .diarization }?.id)
        store.settings.labelRecordedSpeakers = false
        store.isSchedulingManagedTasks = false
        await store.recoverUnfinishedManagedTasks()
        let task = try #require(store.managedTask(id: taskID))
        #expect(task.state == .cancelled)
        #expect(store.managedTaskOperations[taskID] == nil)
        #expect(store.meeting(id: meeting.id)?.speakerLabelSource == nil)
    }

    @Test func fullAudioFallbackKeepsAutomaticIntentAndHonorsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.settings.labelRecordedSpeakers = true
        try FileManager.default.removeItem(
            at: store.directory(for: meeting.id)
                .appendingPathComponent(SpeakerEvidenceInputReceipt.fileName))
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let task = try #require(store.managedTasks.first { $0.kind == .diarization })
        #expect(task.isAutomatic)
        #expect(task.consolidatesRetainedVoiceEvidence == nil)
        #expect(task.providerID == provider.id)
        await store.cancelLocalDiarization(id: meeting.id)
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTask(id: task.id)?.state == .cancelled)
        let manual = try #require(await store.queueSpeakerLabeling(id: meeting.id))
        #expect(manual == task.id)
        #expect(store.managedTask(id: manual)?.isAutomatic == false)
        await store.cancelLocalDiarization(id: meeting.id)
    }

    @Test func consolidationAndFullLabelingShareReservationAndAllowExplicitReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        let taskID = try #require(await store.queueSpeakerConsolidation(id: meeting.id))
        #expect(await store.queueSpeakerLabeling(id: meeting.id) == nil)
        await store.cancelLocalDiarization(id: meeting.id)
        let replacement = try #require(await store.queueSpeakerLabeling(id: meeting.id))
        #expect(replacement == taskID)
        #expect(store.managedTasks.first { $0.id == replacement }?.consolidatesRetainedVoiceEvidence == nil)
        #expect(await store.queueSpeakerConsolidation(id: meeting.id) == nil)
        await store.cancelLocalDiarization(id: meeting.id)
    }
}
