import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordedSpeakerSchedulingTests {
    private func fixture(root: URL) async throws
        -> (MeetingStore, Meeting, URL)
    {
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        store.settings.recognizeSpeakers = false
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.isSchedulingManagedTasks = true
        var meeting = Meeting(title: "Synthetic scheduling")
        meeting.audioFiles = ["microphone.wav"]
        meeting.transcript = [.init(start: 0, end: 3, text: "Synthetic speech.", source: .microphone)]
        let directory = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("microphone.wav")
        try Data([0, 1, 2, 3]).write(to: audio)
        try await store.insertImportedMeeting(meeting)
        return (store, meeting, audio)
    }

    @Test func savedAudioDiarizationUsesConfiguredProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        store.settings.labelRecordedSpeakers = true
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let task = try #require(store.managedTasks.first { $0.kind == .diarization })
        #expect(task.isAutomatic)
        #expect(task.providerID == store.settings.diarizationProviderID)
        await store.cancelLocalDiarization(id: meeting.id)
    }

    @Test func cloudOnlyTranscriptDoesNotQueueAudioAnalysisOrReportConfigurationError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        store.settings.serviceProviders = []
        store.settings.labelRecordedSpeakers = true
        let id = await store.createMeeting(title: "Remote transcript only")
        await store.scheduleAutomaticSpeakerLabeling(id: id)
        #expect(store.managedTasks.allSatisfy { $0.kind != .diarization })
        #expect(store.errorMessage == nil)
    }

    @Test func automaticSavedAudioLabelingHonorsSetting() async throws {
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
        await store.cancelLocalDiarization(id: meeting.id)
    }

    @Test func stoppingWithFinalLiveTextQueuesSavedAudioLabelingWithoutTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        store.isSchedulingManagedTasks = true
        let provider = ServiceProvider(kind: .speakerLabeling)
        store.settings.serviceProviders = [provider]
        store.settings.diarizationProviderID = provider.id
        store.settings.labelRecordedSpeakers = true
        store.settings.recognizeSpeakers = false
        let id = await store.createMeeting(title: "Stop and label saved audio")
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = ["microphone.wav"]
        try Data([0, 1, 2, 3]).write(to: store.directory(for: id).appendingPathComponent("microphone.wav"))
        #expect(await store.updateMeeting(meeting))
        store.recordingID = id
        store.liveTranscript.begin(
            meetingID: id, language: "en", directory: store.directory(for: id),
            sources: [.microphone], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        store.liveTranscript.finalizeDetachedSession(
            token: token,
            work: {
                store.liveTranscript.receive(
                    .init(session: UUID(), source: .microphone, start: 0, end: 2, text: "Final speech"),
                    final: true, token: token)
                return true
            }, cancel: nil)
        await store.stopRecording(transcribeAfter: false)
        await store.scheduleAutomaticSpeakerLabeling(id: id)
        let tasks = store.managedTasks.filter { $0.kind == .diarization }
        #expect(tasks.count == 1)
        #expect(tasks.first?.providerID == provider.id)
        #expect(store.managedTasks.allSatisfy { $0.kind != .transcription })
        let saved = try #require(store.meeting(id: id))
        #expect(saved.liveTranscriptAdopted)
        #expect(saved.transcript.map(\.text) == ["Final speech"])
        #expect(saved.speakerLabelSource == nil)
        #expect(saved.speakers.allSatisfy { $0.personID == nil && $0.voiceEmbedding == nil })
        await store.cancelLocalDiarization(id: id)
    }

    @Test func savedAudioLabelingNeverStartsWhileMeetingIsRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, meeting, _) = try await fixture(root: root)
        store.recordingID = meeting.id
        store.settings.labelRecordedSpeakers = true
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTasks.filter { $0.kind == .diarization }.isEmpty)
        store.recordingID = nil
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
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        let task = try #require(store.managedTasks.first { $0.kind == .diarization })
        #expect(task.isAutomatic)
        #expect(task.providerID == provider.id)
        await store.cancelLocalDiarization(id: meeting.id)
        await store.scheduleAutomaticSpeakerLabeling(id: meeting.id)
        #expect(store.managedTask(id: task.id)?.state == .cancelled)
        let manual = try #require(await store.queueSpeakerLabeling(id: meeting.id))
        #expect(manual == task.id)
        #expect(store.managedTask(id: manual)?.isAutomatic == false)
        await store.cancelLocalDiarization(id: meeting.id)
    }

}
