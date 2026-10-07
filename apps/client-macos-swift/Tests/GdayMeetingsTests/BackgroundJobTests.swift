import Foundation
import Testing

@testable import GdayMeetings

/// Holds a response on the fixture's dedicated dispatch queue, with a deadline
/// so a failed assertion cannot leave the networking fixture blocked forever.
private final class BackgroundResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var received = false
    private var expired = false
    var hasRequest: Bool { lock.withLock { received } }
    var timedOut: Bool { lock.withLock { expired } }
    func wait() {
        lock.withLock { received = true }
        let result = release.wait(timeout: .now() + 5)
        lock.withLock { expired = result == .timedOut }
    }
    func resume() { release.signal() }
}

@MainActor struct BackgroundJobTests {
    @Test(arguments: [false, true]) func suspendedProviderRequestPreservesEditsAndAllowsRecording(chat: Bool)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BackgroundResponseGate()
        let server = try HTTPFixture { _ in
            gate.wait()
            return .init(body: #"{"choices":[{"message":{"content":"Provider answer"}}]}"#)
        }
        try await server.start()
        defer {
            gate.resume()
            server.stop()
        }
        let store = MeetingStore(dataDirectory: root)
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture-model"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        let id = await store.createMeeting(title: "Provider request")
        var meeting = try #require(store.meetings.first { $0.id == id })
        meeting.notes = "Original notes"
        await store.updateMeeting(meeting)
        let operation = Task {
            if chat {
                await store.sendChat(id: id, message: "What did we decide?")
            }
            else {
                await store.summarize(id: id)
            }
        }
        defer { operation.cancel() }
        let receivedRequest = try await waitForMainActorTestCondition { gate.hasRequest }
        try #require(receivedRequest, "The provider request must reach the loopback fixture.")
        let kind: BackgroundJob.Kind = chat ? .chat : .summary
        #expect(store.isJobRunning(kind, .meeting(id)))
        #expect(store.canStartRecording)
        // The real operation has suspended in URLSession. Repeated actions must
        // return without submitting another request or adding another chat turn.
        if chat {
            await store.sendChat(id: id, message: "Duplicate question")
        }
        else {
            await store.summarize(id: id)
        }
        var edited = try #require(store.meetings.first { $0.id == id })
        edited.title = "Edited while waiting"
        edited.notes = "Notes added while waiting"
        await store.updateMeeting(edited)
        gate.resume()
        await operation.value
        #expect(!gate.timedOut)
        #expect(server.requests.count == 1)
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.canStartRecording)
        #expect(store.errorMessage == nil)
        let reopened = MeetingStore(dataDirectory: root)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        let saved = try #require(reopened.meeting(id: id))
        #expect(saved.title == edited.title)
        #expect(saved.notes == edited.notes)
        if chat {
            #expect(saved.chat.map(\.content) == ["What did we decide?", "Provider answer"])
        }
        else {
            #expect(saved.summary.isEmpty)
            #expect(store.managedTasks.last?.state == .failed)
            #expect(store.managedTasks.last?.errorMessage?.contains("transcript or notes changed") == true)
        }
    }

    @Test func quitRejectsNewNonmanagedJobs() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.isPreparingToQuit = true
        for kind in [BackgroundJob.Kind.chat, .contextChat, .archive, .importAudio] {
            #expect(!store.beginJob(kind, .library, progress: "Starting"))
        }
        #expect(store.backgroundJobs.isEmpty)
    }

    @Test func independentJobsKeepRecordingAvailableAndRetainTheirProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let first = await store.createMeeting(title: "Planning")
        let second = await store.createMeeting(title: "Review")
        #expect(store.beginJob(.transcription, .meeting(first), progress: "Uploading audio…"))
        #expect(!store.beginJob(.transcription, .meeting(first), progress: "Duplicate"))
        #expect(store.beginJob(.transcription, .meeting(second), progress: "Transcribing…"))
        #expect(store.beginJob(.summary, .meeting(first), progress: "Writing summary…"))
        #expect(store.canStartRecording)
        store.endJob(.summary, .meeting(first))
        #expect(store.statusMessage == "Review: Transcribing…")
        store.setJobProgress(.transcription, .meeting(first), "Transcribing…")
        store.endJob(.transcription, .meeting(second))
        #expect(store.statusMessage == "Planning: Transcribing…")
        store.recordingID = second
        #expect(!store.canStartRecording)
        store.recordingID = nil
        store.isFinalizingRecording = true
        #expect(!store.canStartRecording)
        store.isFinalizingRecording = false
        store.endJob(.transcription, .meeting(first))
        #expect(store.statusMessage.isEmpty)
        #expect(store.canStartRecording)
    }

    @Test func failedSummaryDoesNotEndAnotherMeetingsTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let first = await store.createMeeting(title: "Transcribing")
        let second = await store.createMeeting(title: "Summary")
        var meeting = try #require(store.meetings.first { $0.id == second })
        meeting.notes = "Discuss delivery."
        await store.updateMeeting(meeting)
        #expect(store.beginJob(.transcription, .meeting(first), progress: "Transcribing…"))
        await store.summarize(id: second)
        #expect(store.errorMessage == nil)
        #expect(store.managedTasks.last?.errorMessage == "Choose and enable a summary provider in Settings → General.")
        #expect(!store.isJobRunning(.summary, .meeting(second)))
        #expect(store.isJobRunning(.transcription, .meeting(first)))
        #expect(store.canStartRecording)
    }

    @Test func importingTracksBlocksOnlyThatMeetingsAudioJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let first = await store.createMeeting(title: "Importing")
        let second = await store.createMeeting(title: "Other meeting")
        #expect(store.beginJob(.importAudio, .meeting(first), progress: "Importing audio…"))
        #expect(store.isImportingAudio)
        #expect(store.canStartRecording)
        await store.transcribe(id: first)
        await store.archiveToServer(id: first)
        // Both return before provider validation or network requests.
        #expect(store.errorMessage == nil)
        await store.transcribe(id: second)
        #expect(store.errorMessage == nil)
        #expect(store.managedTasks.last?.errorMessage == "Choose a transcription provider in Settings → General.")
        store.endJob(.importAudio, .meeting(first))
        #expect(!store.isImportingAudio)
    }

    @Test func corruptSettingsCannotStartRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: root.appendingPathComponent("settings.json"))
        let store = MeetingStore(dataDirectory: root)
        #expect(!store.canStartRecording)
    }

    @Test func runningMeetingJobProtectsDeletionAndPendingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Pending transcription")
        let attempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://example.test", kind: .runpod, title: "Pending transcription")
        try await store.saveTranscriptionAttempt(attempt, meetingID: id)
        #expect(store.beginJob(.transcription, .meeting(id), progress: "Transcribing…"))
        #expect(!(await store.deleteMeeting(id: id)))
        #expect(store.meetings.contains { $0.id == id })
        await #expect(throws: (any Error).self) { try await store.clearTranscriptionAttempt(meetingID: id) }
        #expect(store.meetings.first?.transcriptionAttempt == attempt)
        store.endJob(.transcription, .meeting(id))
        try await store.clearTranscriptionAttempt(meetingID: id)
        #expect(store.meetings.first?.transcriptionAttempt == nil)
        #expect(await store.deleteMeeting(id: id))
        #expect(store.meetings.isEmpty)
        let retained = store.containsMeeting(id: id)
        let indexed = try store.libraryIndex?.entry(id: id)
        #expect(
            !retained,
            "Loaded \(store.meetings.contains { $0.id == id }), index \(String(describing: indexed)), metadata \(FileManager.default.fileExists(atPath: store.directory(for: id).appendingPathComponent("metadata.json").path)), index error \(String(describing: store.libraryDataStatus.error))"
        )
        #expect(store.meetingPageError == nil)
    }
}
