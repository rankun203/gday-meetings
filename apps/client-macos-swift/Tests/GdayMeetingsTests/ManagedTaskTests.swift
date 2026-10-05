import Foundation
import Testing

@testable import GdayMeetings

private final class QueueProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private var complete = false
    var count: Int { lock.withLock { polls } }
    func finish() { lock.withLock { complete = true } }
    func response(after count: Int? = nil) -> HTTPFixture.Response {
        let done = lock.withLock {
            polls += 1
            return complete || count.map { polls > $0 } == true
        }
        if done {
            return .init(
                body:
                    #"{"status":"COMPLETED","output":{"tracks":{"mic":{"segments":[{"start":0.0,"end":1.0,"text":"Completed transcript"}]}}}}"#
            )
        }
        return .init(body: #"{"status":"IN_QUEUE"}"#)
    }
}

private final class SummaryQueueResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var receivedFirst = false

    func waitForReleaseOnFirstResponse() {
        let first = lock.withLock {
            guard !receivedFirst else { return false }
            receivedFirst = true
            return true
        }
        if first { signal.wait() }
    }

    func release() { signal.signal() }
}

@MainActor struct ManagedTaskTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func configure(_ store: MeetingStore, origin: String) -> ServiceProvider {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = origin + "/v2/test"
        provider.apiKey = "fixture-key"
        provider.enabledCapabilities = [.transcription]
        store.settings.serviceProviders = [provider]
        store.settings.transcriptionProviderID = provider.id
        store.transcriptionPollDelay = .milliseconds(5)
        return provider
    }
    private func savedAttempt(_ store: MeetingStore, provider: ServiceProvider, title: String) async throws -> UUID {
        let id = await store.createMeeting(title: title)
        let meeting = try #require(store.meetings.first { $0.id == id })
        var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        attempt.taskID = id.uuidString
        attempt.inputs = [
            .init(url: URL(string: "https://audio.example/mic.wav")!, trackName: "mic", sourceType: "mic", channels: 1)
        ]
        try await store.saveTranscriptionAttempt(attempt, meetingID: id)
        return id
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func differentMeetingsRunTogetherAndNextCanBeReorderedOrRemoved() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = QueueProviderState()
        let server = try HTTPFixture { _ in state.response() }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: server.origin)
        var meetings: [UUID] = []
        for index in 0..<4 {
            meetings.append(try await savedAttempt(store, provider: provider, title: "Meeting \(index)"))
        }
        var tasks: [UUID] = []
        for meeting in meetings { tasks.append(try #require(await store.queueTranscription(id: meeting))) }
        #expect(store.managedTasks.filter { $0.state == .running }.count == 2)
        #expect(store.managedTasks.filter { $0.state == .queued }.count == 2)
        #expect(await store.queueTranscription(id: meetings[0]) == nil)
        #expect(await store.queueTranscription(id: meetings[2]) == nil)
        #expect(store.isJobRunning(.transcription, .meeting(meetings[2])))
        await store.prioritizeManagedTask(id: tasks[3])
        #expect(
            store.managedTasks.filter { $0.state == .queued }.max(by: { $0.queuePriority < $1.queuePriority })?.id
                == tasks[3])
        await store.removeManagedTask(id: tasks[2])
        #expect(!store.managedTasks.contains { $0.id == tasks[2] })
        try await waitUntil { state.count >= 2 }
        state.finish()
        try await waitUntil { store.backgroundJobs.isEmpty }
        #expect(store.managedTasks.allSatisfy { $0.state == .completed })
        #expect(!server.requests.contains { $0.target.contains(meetings[2].uuidString) })
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.contains("/status/") })
        #expect(store.errorMessage == nil)
    }

    @Test func pendingPollsContinueBeyondFormerLimit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = QueueProviderState()
        let server = try HTTPFixture { _ in state.response(after: 155) }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: server.origin)
        store.transcriptionPollDelay = .zero
        let id = try await savedAttempt(store, provider: provider, title: "Long provider queue")
        await store.transcribe(id: id)
        #expect(state.count == 156)
        #expect(store.managedTasks.last?.state == .completed)
        #expect(store.meetings.first?.transcript.first?.text == "Completed transcript")
        #expect(store.errorMessage == nil)
    }

    @Test func stopWaitingRetainsJobAndResumeDoesNotResubmit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = QueueProviderState()
        let server = try HTTPFixture { _ in state.response() }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: server.origin)
        let id = try await savedAttempt(store, provider: provider, title: "Resume existing job")
        let taskID = try #require(await store.queueTranscription(id: id))
        try await waitUntil { state.count > 0 }
        await store.cancelManagedTask(id: taskID)
        await store.waitForManagedTask(taskID)
        let cancelled = try #require(store.managedTasks.first { $0.id == taskID })
        #expect(cancelled.state == .cancelled)
        #expect(store.meetings.first?.transcriptionAttempt?.taskID == id.uuidString)
        #expect(store.canRetryManagedTask(cancelled))
        state.finish()
        await store.retryManagedTask(id: taskID)
        try await waitUntil { store.backgroundJobs.isEmpty }
        #expect(store.managedTasks.count == 1)
        #expect(store.managedTasks.first?.state == .completed)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.hasSuffix("/status/" + id.uuidString) })
    }

    @Test func ambiguousAttemptCannotRetryAndBackgroundFailureDoesNotShowAlert() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Missing provider")
        await store.transcribe(id: id)
        #expect(store.managedTasks.last?.state == .failed)
        #expect(store.managedTasks.last?.errorMessage == "Choose a transcription provider in Settings → General.")
        #expect(store.errorMessage == nil)
        var meeting = try #require(store.meetings.first)
        var attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: meeting)
        attempt.submissionUncertain = true
        meeting.transcriptionAttempt = attempt
        await store.updateMeeting(meeting)
        #expect(!store.canRetryManagedTask(try #require(store.managedTasks.last)))
    }

    @Test func disablingQueuedAutomaticSummaryDoesNotExceedSummaryLimit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SummaryQueueResponseGate()
        defer { gate.release() }
        let server = try HTTPFixture { _ in
            gate.waitForReleaseOnFirstResponse()
            return .init(body: #"{"choices":[{"message":{"content":"Summary"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        store.settings.autoSummarize = true
        var ids: [UUID] = []
        for index in 0..<4 { ids.append(await store.createMeeting(title: "Summary \(index)")) }
        for id in ids {
            var meeting = try #require(store.meetings.first { $0.id == id })
            meeting.transcript = [.init(text: "Meeting words")]
            await store.updateMeeting(meeting)
        }
        await store.queueSummary(id: ids[0])
        let automatic = try #require(await store.queueSummary(id: ids[1], automatically: true))
        await store.queueSummary(id: ids[2])
        await store.queueSummary(id: ids[3])
        // Durable admission can take longer than a fixed response delay. Keep
        // the first request running until this test has disabled queued work.
        #expect(store.managedTasks.first { $0.id == automatic }?.state == .queued)
        store.settings.autoSummarize = false
        gate.release()
        let finished = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            #expect(store.managedTasks.filter { $0.state == .running }.count <= 1)
            return store.managedTaskStateCounts[.queued, default: 0] == 0
                && store.managedTaskStateCounts[.running, default: 0] == 0
        }
        try #require(finished)
        #expect(store.managedTasks.first { $0.id == automatic }?.state == .cancelled)
        #expect(server.requests.count == 3)
    }

    @Test func existingTranscriptionAttemptsDoNotCreateTaskRecords() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: "https://provider.example.invalid")
        let id = try await savedAttempt(store, provider: provider, title: "Existing attempt")
        let recovered = MeetingStore(dataDirectory: root)
        #expect(recovered.managedTasks.isEmpty)
        #expect(recovered.backgroundJobs.isEmpty)
        #expect(await recovered.ensureMeetingLoaded(id: id))
        #expect(recovered.meeting(id: id)?.transcriptionAttempt?.taskID == id.uuidString)
    }

    @Test func unfinishedTranscriptionsResumeAutomaticallyWithoutResubmission() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = QueueProviderState()
        state.finish()
        let server = try HTTPFixture { _ in state.response() }
        try await server.start()
        defer { server.stop() }
        // Freeze the previous persistence owner before relaunching. Async
        // observers may retain it briefly, so deallocation is not the boundary.
        let provider: ServiceProvider
        do {
            let store = MeetingStore(dataDirectory: root)
            provider = configure(store, origin: server.origin)
            store.saveSettings()
            var ids: [UUID] = []
            for index in 0..<2 {
                ids.append(try await savedAttempt(store, provider: provider, title: "Recover \(index)"))
            }
            for id in ids {
                let attempt = try #require(store.meetings.first { $0.id == id }?.transcriptionAttempt)
                let row = ManagedTaskRecord(
                    kind: .transcription, meetingID: id, meetingTitle: "Recover",
                    providerID: provider.id, state: .running, attemptKey: attempt.idempotencyKey,
                    remoteJobID: attempt.taskID)
                try store.managedTaskJournal.upsert(row)
            }
            #expect(await store.finalizeForQuit())
        }
        let recovered = MeetingStore(dataDirectory: root)
        // Test stores do not load Keychain; restore the synthetic credential before recovery runs.
        recovered.settings.serviceProviders = [provider]
        recovered.transcriptionPollDelay = .milliseconds(1)
        try await waitUntil {
            !recovered.managedTasksLoading && recovered.managedTasks.count == 2
                && recovered.managedTasks.allSatisfy { $0.state == .completed }
        }
        #expect(recovered.managedTasks.count == 2)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.contains("/status/") })
        #expect(recovered.meetings.allSatisfy { $0.transcriptionAttempt == nil })
    }
}
