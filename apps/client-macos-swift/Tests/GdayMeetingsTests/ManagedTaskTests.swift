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
    private func savedAttempt(_ store: MeetingStore, provider: ServiceProvider, title: String) throws -> UUID {
        let id = store.createMeeting(title: title)
        let meeting = try #require(store.meetings.first { $0.id == id })
        var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        attempt.taskID = id.uuidString
        attempt.inputs = [
            .init(url: URL(string: "https://audio.example/mic.wav")!, trackName: "mic", sourceType: "mic", channels: 1)
        ]
        try store.saveTranscriptionAttempt(attempt, meetingID: id)
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
        let meetings = try (0..<4).map { try savedAttempt(store, provider: provider, title: "Meeting \($0)") }
        let tasks = try meetings.map { try #require(store.queueTranscription(id: $0)) }
        #expect(store.managedTasks.filter { $0.state == .running }.count == 2)
        #expect(store.managedTasks.filter { $0.state == .queued }.count == 2)
        #expect(store.queueTranscription(id: meetings[0]) == nil)
        #expect(store.queueTranscription(id: meetings[2]) == nil)
        #expect(store.isJobRunning(.transcription, .meeting(meetings[2])))
        store.prioritizeManagedTask(id: tasks[3])
        #expect(store.managedTasks.first { $0.state == .queued }?.id == tasks[3])
        store.removeManagedTask(id: tasks[2])
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
        let id = try savedAttempt(store, provider: provider, title: "Long provider queue")
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
        let id = try savedAttempt(store, provider: provider, title: "Resume existing job")
        let taskID = try #require(store.queueTranscription(id: id))
        try await waitUntil { state.count > 0 }
        store.cancelManagedTask(id: taskID)
        await store.waitForManagedTask(taskID)
        let cancelled = try #require(store.managedTasks.first { $0.id == taskID })
        #expect(cancelled.state == .cancelled)
        #expect(store.meetings.first?.transcriptionAttempt?.taskID == id.uuidString)
        #expect(store.canRetryManagedTask(cancelled))
        state.finish()
        store.retryManagedTask(id: taskID)
        try await waitUntil { store.backgroundJobs.isEmpty }
        #expect(store.managedTasks.count == 1)
        #expect(store.managedTasks.first?.state == .completed)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.target.hasSuffix("/status/" + id.uuidString) })
    }

    @Test func ambiguousAttemptCannotRetryAndBackgroundFailureDoesNotShowAlert() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Missing provider")
        await store.transcribe(id: id)
        #expect(store.managedTasks.last?.state == .failed)
        #expect(store.managedTasks.last?.errorMessage == "Choose a transcription provider in Settings → Defaults.")
        #expect(store.errorMessage == nil)
        var meeting = try #require(store.meetings.first)
        var attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: meeting)
        attempt.submissionUncertain = true
        meeting.transcriptionAttempt = attempt
        store.updateMeeting(meeting)
        #expect(!store.canRetryManagedTask(try #require(store.managedTasks.last)))
    }

    @Test func disablingQueuedAutomaticSummaryDoesNotExceedSummaryLimit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            Thread.sleep(forTimeInterval: 0.03)
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
        let ids = (0..<4).map { store.createMeeting(title: "Summary \($0)") }
        for id in ids {
            var meeting = try #require(store.meetings.first { $0.id == id })
            meeting.transcript = [.init(text: "Meeting words")]
            store.updateMeeting(meeting)
        }
        store.queueSummary(id: ids[0])
        let automatic = try #require(store.queueSummary(id: ids[1], automatically: true))
        store.queueSummary(id: ids[2])
        store.queueSummary(id: ids[3])
        store.settings.autoSummarize = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.backgroundJobs.isEmpty && ContinuousClock.now < deadline {
            #expect(store.managedTasks.filter { $0.state == .running }.count <= 1)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.managedTasks.first { $0.id == automatic }?.state == .cancelled)
        #expect(server.requests.count == 3)
    }

    @Test func existingTranscriptionAttemptsDoNotCreateTaskRecords() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: "https://provider.example.invalid")
        let id = try savedAttempt(store, provider: provider, title: "Existing attempt")
        let recovered = MeetingStore(dataDirectory: root)
        #expect(recovered.managedTasks.isEmpty)
        #expect(recovered.backgroundJobs.isEmpty)
        #expect(recovered.meetings.first?.transcriptionAttempt?.taskID == id.uuidString)
    }

    @Test func queuedIntentsRecoverWithoutStartingRequests() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = QueueProviderState()
        let server = try HTTPFixture { _ in state.response() }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let provider = configure(store, origin: server.origin)
        store.saveSettings()
        let first = try savedAttempt(store, provider: provider, title: "First")
        let second = try savedAttempt(store, provider: provider, title: "Second")
        let third = store.createMeeting(title: "Not submitted yet")
        let taskIDs = try [first, second, third].map { try #require(store.queueTranscription(id: $0)) }
        #expect(store.managedTasks.last?.state == .queued)
        let recovered = MeetingStore(dataDirectory: root)
        #expect(recovered.managedTasks.count == 3)
        #expect(recovered.managedTasks.allSatisfy { $0.state == .failed && $0.interrupted })
        #expect(recovered.backgroundJobs.isEmpty)
        #expect(recovered.managedTaskOperations.isEmpty)
        #expect(
            recovered.managedTasks.contains { $0.meetingID == third && $0.errorMessage?.contains("queued") == true })
        for taskID in taskIDs { store.cancelManagedTask(id: taskID) }
        for taskID in taskIDs { await store.waitForManagedTask(taskID) }
        #expect(!server.requests.contains { $0.target.contains(third.uuidString) })
    }
}
