import Foundation
import Testing

@testable import GdayMeetings

private final class RecoveryResponseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

@MainActor struct ManagedTaskRecoveryTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func seed(_ store: MeetingStore, origin: String) throws -> (
        ServiceProvider, UUID, ProviderTranscriptionAttempt
    ) {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = origin + "/v2/fixture"
        provider.apiKey = "fixture-key"
        provider.enabledCapabilities = [.transcription]
        store.settings.serviceProviders = [provider]
        store.settings.transcriptionProviderID = provider.id
        store.transcriptionPollDelay = .milliseconds(1)
        let id = store.createMeeting(title: "Recover task")
        let meeting = try #require(store.meetings.first { $0.id == id })
        var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        attempt.taskID = "saved-job"
        attempt.inputs = [
            .init(url: URL(string: "https://audio.example/mic.wav")!, trackName: "mic", sourceType: "mic", channels: 1)
        ]
        try store.saveTranscriptionAttempt(attempt, meetingID: id)
        return (provider, id, attempt)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let reached = try await waitForMainActorTestCondition(condition)
        try #require(reached)
    }

    @Test func wakeDuringRequestThenTransientFailureKeepsPollingSameJob() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RecoveryResponseCounter()
        let server = try HTTPFixture { _ in
            if counter.next() == 1 { return .init(status: 503) }
            return .init(
                body:
                    #"{"status":"COMPLETED","output":{"tracks":{"mic":{"segments":[{"start":0.0,"end":1.0,"text":"Recovered"}]}}}}"#
            )
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let (_, id, _) = try seed(store, origin: server.origin)
        let taskID = try #require(store.queueTranscription(id: id))
        // Wake can arrive while the existing operation is still alive.
        store.recoverUnfinishedManagedTasks()
        await store.waitForManagedTask(taskID)
        #expect(store.managedTasks.count == 1)
        #expect(store.managedTasks.first?.state == .completed)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.hasSuffix("/status/saved-job") })
    }

    @Test func missingJobOffersExplicitRestartAndClearsOnlyItsCheckpoint() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in .init(status: 404) }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let (_, id, _) = try seed(store, origin: server.origin)
        await store.transcribe(id: id)
        let task = try #require(store.managedTasks.first)
        #expect(task.recovery == .restartRequired)
        #expect(store.canRestartManagedTask(task))
        #expect(!store.canRetryManagedTask(task))
        #expect(store.meetings.first?.transcriptionAttempt?.remoteJobExpired == true)
        store.recoverUnfinishedManagedTasks()
        #expect(server.requests.count == 1)
        store.restartManagedTask(id: task.id)
        #expect(store.managedTasks.count == 1)
        #expect(store.managedTasks.first?.id == task.id)
        #expect(store.meetings.first?.transcriptionAttempt == nil)
        #expect(store.managedTasks.first?.attemptKey == nil)
        // Stop before the new submission. Restart's durable reset is independent
        // of the already-covered upload/submission adapter.
        store.cancelManagedTask(id: task.id)
        await store.waitForManagedTask(task.id)
        #expect(server.requests.allSatisfy { $0.target.hasSuffix("/status/saved-job") })
    }

    @Test func legacyPolling404ResumesOnlyTheSavedJobThenRequiresRestart() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in .init(status: 404) }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let (provider, id, attempt) = try seed(store, origin: server.origin)
        let row = ManagedTaskRecord(
            kind: .transcription, meetingID: id, meetingTitle: "Saved status failure",
            providerID: provider.id, state: .failed,
            errorMessage: ServiceHTTPStatusError(statusCode: 404).localizedDescription,
            recovery: .manual, attemptKey: attempt.idempotencyKey, remoteJobID: attempt.taskID)
        try store.managedTaskJournal.upsert(row)
        store.managedTasks = [row]
        store.recoverUnfinishedManagedTasks()
        #expect(server.requests.isEmpty)
        store.retryManagedTask(id: row.id)
        await store.waitForManagedTask(row.id)
        #expect(store.managedTasks.first?.recovery == .restartRequired)
        #expect(store.meetings.first?.transcriptionAttempt?.remoteJobExpired == true)
        #expect(server.requests.count == 1)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.hasSuffix("/status/saved-job") })
        store.recoverUnfinishedManagedTasks()
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func preflight404NamesFailingProviderWithoutExpiringOrSubmittingJob(uploadFailure: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { request in
            if uploadFailure && request.target == "/v2/fixture/health" {
                return .init(body: #"{"workers":{},"jobs":{}}"#)
            }
            return .init(status: 404)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        var (provider, id, attempt) = try seed(store, origin: server.origin)
        var upload = ServiceProvider(kind: .filedrop)
        upload.name = "Example Uploads"
        upload.endpoint = server.origin + "/uploads"
        upload.apiKey = "fixture-key"
        upload.enabledCapabilities = [.fileTransfer]
        provider.name = "Example Transcription"
        provider.uploadProviderID = upload.id
        store.settings.serviceProviders = [provider, upload]
        attempt.taskID = nil
        attempt.inputs = []
        try store.saveTranscriptionAttempt(attempt, meetingID: id)
        await store.transcribe(id: id)
        let task = try #require(store.managedTasks.first)
        #expect(task.state == .failed)
        #expect(task.recovery == .manual)
        #expect(!store.canRestartManagedTask(task))
        #expect(task.errorMessage?.contains(uploadFailure ? upload.name : provider.name) == true)
        #expect(task.errorMessage?.contains("No transcription job was submitted.") == true)
        #expect(store.meetings.first?.transcriptionAttempt?.remoteJobExpired != true)
        #expect(store.meetings.first?.transcriptionAttempt?.taskID == nil)
        #expect(server.requests.count == (uploadFailure ? 2 : 1))
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.hasSuffix("/health") })
        store.recoverUnfinishedManagedTasks()
        #expect(server.requests.count == (uploadFailure ? 2 : 1))
    }

    @Test func endpoint404OutsideJobPollingDoesNotOfferRestart() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in .init(status: 404) }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        let id = store.createMeeting(title: "Endpoint error")
        var meeting = try #require(store.meetings.first)
        meeting.notes = "Summarize these notes."
        store.updateMeeting(meeting)
        await store.summarize(id: id)
        let task = try #require(store.managedTasks.first)
        #expect(task.state == .failed)
        #expect(task.recovery == .manual)
        #expect(!store.canRestartManagedTask(task))
    }

    @Test(arguments: [false, true]) func dismissClearsOwnAttemptButNeverLaterRequest(laterRequest: Bool) throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let (provider, id, attempt) = try seed(store, origin: "https://provider.example.invalid")
        let task = ManagedTaskRecord(
            kind: .transcription, meetingID: id, meetingTitle: "Dismiss",
            providerID: provider.id, state: .failed, recovery: .manual, attemptKey: attempt.idempotencyKey)
        try store.managedTaskJournal.upsert(task)
        store.managedTasks = [task]
        if laterRequest {
            var next = attempt
            next.idempotencyKey = UUID().uuidString
            next.taskID = "newer-job"
            try store.saveTranscriptionAttempt(next, meetingID: id)
        }
        store.removeManagedTask(id: task.id)
        #expect(store.managedTasks.isEmpty)
        if laterRequest {
            #expect(store.meetings.first?.transcriptionAttempt?.taskID == "newer-job")
        }
        else {
            #expect(store.meetings.first?.transcriptionAttempt == nil)
        }
        #expect(try ManagedTaskJournal(url: root.appendingPathComponent("tasks.jsonl")).load().isEmpty)
    }

    @Test(arguments: [BackgroundJob.Kind.transcription, .summary])
    func savedResultReceiptCompletesInterruptedRowWithoutProviderRequest(kind: BackgroundJob.Kind) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Output committed before crash")
        let task = ManagedTaskRecord(
            kind: kind, meetingID: id, meetingTitle: "Output committed", state: .running,
            attemptKey: kind == .transcription ? "previous-request" : nil)
        var meeting = try #require(store.meetings.first)
        meeting.completedTaskIDs[kind.rawValue] = task.id
        meeting.summary = "Durable generated output"
        store.updateMeeting(meeting)
        try store.managedTaskJournal.upsert(task)
        let recovered = MeetingStore(dataDirectory: root)
        try await waitUntil { recovered.managedTasks.first?.state == .completed }
        #expect(recovered.managedTasks.first?.id == task.id)
        #expect(recovered.managedTaskOperations.isEmpty)
        #expect(recovered.managedTasks.first?.errorMessage == nil)
    }

    @Test func boundRequestWithoutCheckpointNeverAutomaticallySubmits() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Missing checkpoint")
        let task = ManagedTaskRecord(
            kind: .transcription, meetingID: id, meetingTitle: "Missing checkpoint",
            state: .running, attemptKey: "old-request", remoteJobID: "old-job")
        try store.managedTaskJournal.upsert(task)
        let recovered = MeetingStore(dataDirectory: root)
        try await waitUntil { recovered.managedTasks.first?.state == .failed }
        #expect(recovered.managedTasks.first?.recovery == .blocked)
        #expect(recovered.managedTaskOperations.isEmpty)
        #expect(recovered.meetings.first?.transcriptionAttempt == nil)
    }

    @Test func unregisteredKindIsAttentionWithoutBlockingJournal() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Future task")
        let task = ManagedTaskRecord(kind: .init(rawValue: "futureExport"), meetingID: id, meetingTitle: "Future task")
        try store.managedTaskJournal.upsert(task)
        let recovered = MeetingStore(dataDirectory: root)
        try await waitUntil { recovered.managedTasks.first?.state == .failed }
        #expect(recovered.managedTasks.first?.recovery == .blocked)
        #expect(recovered.managedTasks.first?.kind.rawValue == "futureExport")
        #expect(recovered.managedTaskJournalError == nil)
    }

    @Test func queuedSummaryStartsAfterLaunchButInFlightSummaryRequiresRetry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in .init(body: #"{"choices":[{"message":{"content":"Recovered summary"}}]}"#) }
        try await server.start()
        defer { server.stop() }
        // A relaunch has one store owner. Keeping the old monitor alive can
        // mistake the recovered owner's journal updates for external edits.
        weak var originalStore: MeetingStore?
        do {
            let store = MeetingStore(dataDirectory: root)
            originalStore = store
            var provider = ServiceProvider(kind: .openAICompatible)
            provider.endpoint = server.origin + "/v1"
            provider.model = "fixture"
            provider.enabledCapabilities = [.summarization]
            store.settings.serviceProviders = [provider]
            store.settings.summaryProviderID = provider.id
            store.saveSettings()
            for (title, state) in [("Unsent", ManagedTaskState.queued), ("Possibly submitted", .running)] {
                let id = store.createMeeting(title: title)
                var meeting = try #require(store.meetings.first { $0.id == id })
                meeting.notes = "Meeting notes"
                store.updateMeeting(meeting)
                try store.managedTaskJournal.upsert(
                    ManagedTaskRecord(
                        kind: .summary, meetingID: id,
                        meetingTitle: title, providerID: provider.id, state: state))
            }
        }
        #expect(originalStore == nil)
        let recovered = MeetingStore(dataDirectory: root)
        try await waitUntil { recovered.managedTasks.first { $0.meetingTitle == "Unsent" }?.state == .completed }
        #expect(recovered.managedTasks.first { $0.meetingTitle == "Possibly submitted" }?.state == .failed)
        #expect(recovered.managedTasks.first { $0.meetingTitle == "Possibly submitted" }?.recovery == .manual)
        #expect(server.requests.count == 1)
    }

    @Test func journalWriteFailurePreventsProviderWork() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in .init(body: "{}") }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let (_, id, _) = try seed(store, origin: server.origin)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tasks.jsonl"), withIntermediateDirectories: true)
        #expect(store.queueTranscription(id: id) == nil)
        #expect(store.managedTaskJournalError != nil)
        #expect(store.backgroundJobs.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func applyingSavedTranscriptCompletesItsTaskReceipt() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let (provider, id, original) = try seed(store, origin: "https://provider.example.invalid")
        var attempt = original
        attempt.result = [.init(text: "Saved result")]
        try store.saveTranscriptionAttempt(attempt, meetingID: id)
        let row = ManagedTaskRecord(
            kind: .transcription, meetingID: id, meetingTitle: "Apply result",
            providerID: provider.id, state: .failed, recovery: .manual, attemptKey: attempt.idempotencyKey,
            remoteJobID: attempt.taskID, hasSavedResult: true)
        try store.managedTaskJournal.upsert(row)
        store.managedTasks = [row]
        store.applySavedTranscriptionResult(meetingID: id)
        #expect(store.managedTasks.first?.state == .completed)
        #expect(store.meetings.first?.completedTaskIDs["transcription"] == row.id)
        #expect(store.meetings.first?.transcriptionAttempt == nil)
    }

    @Test func previewRestartCompletesLocally() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Preview expired task")
        let row = ManagedTaskRecord(
            kind: .transcription, meetingID: id, meetingTitle: "Preview expired task",
            state: .failed, isPreview: true, recovery: .restartRequired)
        store.managedTasks = [row]
        store.restartManagedTask(id: row.id)
        #expect(store.managedTasks.first?.state == .completed)
        #expect(store.managedTaskOperations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks.jsonl").path))
    }

    @Test func oldSnapshotIsNotReadOrMigrated() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("managed-tasks.json")
        let bytes = Data("deliberately invalid old snapshot".utf8)
        try bytes.write(to: legacy)
        let store = MeetingStore(dataDirectory: root)
        #expect(store.managedTasks.isEmpty)
        #expect(store.managedTaskJournalError == nil)
        #expect(try Data(contentsOf: legacy) == bytes)
    }
}
