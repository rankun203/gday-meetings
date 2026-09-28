import Foundation
import Testing

@testable import GdayMeetings

private final class AutomaticSummaryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var count = 0
    private var expired = false
    var requestCount: Int { lock.withLock { count } }
    var timedOut: Bool { lock.withLock { expired } }
    func receive() -> HTTPFixture.Response {
        let index = lock.withLock {
            count += 1
            return count
        }
        if index == 1 {
            let result = signal.wait(timeout: .now() + 5)
            lock.withLock { expired = result == .timedOut }
        }
        return .init(body: "{\"choices\":[{\"message\":{\"content\":\"Summary \(index)\"}}]}")
    }
    func resume() { signal.signal() }
}

@MainActor struct AutomaticSummaryTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func configure(_ store: MeetingStore, endpoint: String) {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = endpoint + "/v1"
        provider.model = "fixture-model"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        store.settings.autoSummarize = true
    }
    private func finishLive(_ store: MeetingStore, id: UUID) async {
        store.recordingID = id
        store.liveTranscript.begin(
            meetingID: id, language: "en", directory: store.directory(for: id),
            sources: [.microphone], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        store.liveTranscript.finalizeDetachedSession(
            token: token,
            work: {
                store.liveTranscript.receive(
                    .init(session: UUID(), source: .microphone, start: 1, end: 2, text: "Saved live words"),
                    final: true, token: token)
                return true
            }, cancel: nil)
        await store.stopRecording(transcribeAfter: false)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let reached = try await waitForMainActorTestCondition(condition)
        try #require(reached)
    }

    @Test func settingDefaultsOffAndPersists() throws {
        #expect(!AppSettings().autoSummarize)
        #expect(!(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))).autoSummarize)
        var settings = AppSettings()
        settings.autoSummarize = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).autoSummarize)
    }

    @Test(arguments: [false, true]) func newerProviderTranscriptQueuesAfterRunningSummary(manualFirst: Bool)
        async throws
    {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AutomaticSummaryGate()
        let server = try HTTPFixture { _ in gate.receive() }
        try await server.start()
        defer {
            gate.resume()
            server.stop()
        }
        let store = MeetingStore(dataDirectory: root)
        configure(store, endpoint: server.origin)
        let id = store.createMeeting(title: "Two transcripts")
        if manualFirst {
            var meeting = try #require(store.meetings.first)
            meeting.transcript = [.init(text: "Saved live words")]
            store.updateMeeting(meeting)
            Task { await store.summarize(id: id) }
        }
        else {
            await finishLive(store, id: id)
            #expect(store.recordingID == nil)
            #expect(!store.isFinalizingRecording)
        }
        try await waitUntil { gate.requestCount == 1 }
        let original = try #require(store.meetings.first)
        let attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: original)
        try store.saveTranscriptionResult([.init(text: "Completed provider words")], attempt: attempt, meetingID: id)
        #expect(store.pendingAutomaticSummaries.contains(id))
        #expect(store.isJobRunning(.summary, .meeting(id)))
        gate.resume()
        try await waitUntil { store.meetings.first?.summary == "Summary 2" && store.backgroundJobs.isEmpty }
        #expect(!gate.timedOut)
        #expect(gate.requestCount == 2)
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies[0].contains("Saved live words"))
        #expect(!bodies[0].contains("Completed provider words"))
        #expect(bodies[1].contains("Completed provider words"))
        #expect(!bodies[1].contains("Saved live words"))
        #expect(MeetingStore(dataDirectory: root).meeting(id: id)?.summary == "Summary 2")
        #expect(store.pendingAutomaticSummaries.isEmpty)
    }

    @Test func disablingAutomationSkipsQueuedProviderTranscript() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AutomaticSummaryGate()
        let server = try HTTPFixture { _ in gate.receive() }
        try await server.start()
        defer {
            gate.resume()
            server.stop()
        }
        let store = MeetingStore(dataDirectory: root)
        configure(store, endpoint: server.origin)
        let id = store.createMeeting(title: "Disable queued summary")
        await finishLive(store, id: id)
        try await waitUntil { gate.requestCount == 1 }
        let original = try #require(store.meetings.first)
        let attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: original)
        try store.saveTranscriptionResult([.init(text: "New words")], attempt: attempt, meetingID: id)
        store.settings.autoSummarize = false
        gate.resume()
        try await waitUntil { store.backgroundJobs.isEmpty }
        #expect(gate.requestCount == 1)
        #expect(store.pendingAutomaticSummaries.isEmpty)
    }

    @Test func disabledEmptyAndDiscardedTranscriptsDoNotSchedule() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "No automatic request")
        var original = try #require(store.meetings.first)
        var attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: original)
        try store.saveTranscriptionResult([.init(text: "Batch words")], attempt: attempt, meetingID: id)
        #expect(store.scheduledAutomaticSummaries.isEmpty)
        store.settings.autoSummarize = true
        original = try #require(store.meetings.first)
        attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: original)
        try store.saveTranscriptionAttempt(attempt, meetingID: id)
        try store.clearTranscriptionAttempt(meetingID: id)
        #expect(store.scheduledAutomaticSummaries.isEmpty)
        try store.saveTranscriptionResult([.init(text: " \n")], attempt: attempt, meetingID: id)
        #expect(store.scheduledAutomaticSummaries.isEmpty)
        #expect(store.pendingAutomaticSummaries.isEmpty)
    }

    @Test func failedTranscriptSaveDoesNotSchedule() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.settings.autoSummarize = true
        let id = store.createMeeting(title: "Failed save")
        let original = try #require(store.meetings.first)
        let attempt = ProviderTranscriptionAttempt(provider: .init(kind: .runpod), meeting: original)
        let index = store.directory(for: id).appendingPathComponent("metadata.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try store.saveTranscriptionResult([.init(text: "Unsaved result")], attempt: attempt, meetingID: id)
        }
        #expect(store.pendingAutomaticSummaries.isEmpty)
        #expect(store.scheduledAutomaticSummaries.isEmpty)
        #expect(store.meetings.first?.transcript.isEmpty == true)
    }
}
