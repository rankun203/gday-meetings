import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SummaryStreamingTests {
    nonisolated private static let first =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"### Summary\\n\\n\"}}]}\r\n\r\n"
    nonisolated private static let second =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"- [ ] Send résumé 👋\"}}]}\n\n"
    nonisolated private static let end =
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func setup(_ store: MeetingStore, origin: String) async -> UUID {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = origin + "/v1"
        provider.model = "fixture"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        let id = await store.createMeeting(title: "Streaming summary")
        var meeting = store.meetings[0]
        meeting.notes = "Send the report."
        meeting.summary = "Saved summary"
        await store.updateMeeting(meeting)
        return id
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func parserHandlesUTF8CRLFCommentsAndSplitEvents() throws {
        var parser = CompletionEventDecoder()
        let multiline = Self.first.replacingOccurrences(of: "{\"choices\":", with: "{\r\ndata: \"choices\":")
        let stream = "\u{FEFF}: heartbeat\r\n\r\n" + multiline + Self.second + Self.end
        var updates: [String] = []
        for byte in stream.utf8 {
            if try parser.receive(byte) { updates.append(parser.text) }
        }
        #expect(updates == ["### Summary\n\n", "### Summary\n\n- [ ] Send résumé 👋"])
        #expect(try parser.result() == updates.last)
        #expect(parser.done)
    }

    @Test func retryRetainsInstructionsAndNewOrdinaryRequestClearsThem() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(headers: ["Content-Type": "text/event-stream"], body: Self.first + Self.end)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        store.settings.serviceProviders[0].enabledCapabilities = []
        let taskID = try #require(await store.queueSummary(id: id, instructions: "Write in English."))
        await store.waitForManagedTask(taskID)
        #expect(store.managedTask(id: taskID)?.state == .failed)
        #expect(server.requests.isEmpty)
        #expect(store.managedTaskJournal.record(id: taskID)?.summaryInstructions == "Write in English.")
        store.settings.serviceProviders[0].enabledCapabilities = [.summarization]
        await store.retryManagedTask(id: taskID)
        await store.waitForManagedTask(taskID)
        #expect(store.managedTask(id: taskID)?.state == .completed)
        let request = try #require(server.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect((messages.first?["content"] as? String)?.hasSuffix("Write in English.") == true)
        let ordinaryID = try #require(await store.queueSummary(id: id))
        await store.waitForManagedTask(ordinaryID)
        #expect(store.managedTask(id: ordinaryID)?.summaryInstructions == nil)
        let ordinary = try #require(server.requests.last)
        #expect(!String(decoding: ordinary.body, as: UTF8.self).contains("## User Instructions"))
    }

    @Test func partialErrorAndLengthLimitNeverCountAsComplete() throws {
        for suffix in [
            "", "data: {\"error\":{\"message\":\"failure\"}}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n",
        ] {
            #expect(throws: (any Error).self) {
                var parser = CompletionEventDecoder()
                for byte in (Self.first + suffix).utf8 { _ = try parser.receive(byte) }
                _ = try parser.result()
            }
        }
    }

    @Test(arguments: [false, true]) func streamShowsDraftBeforeSavingAndRespectsTodoSetting(extract: Bool) async throws
    {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Split a UTF-8 scalar and an SSE JSON event across separate TCP writes.
        let bytes = Data(Self.second.utf8)
        let split = try #require(bytes.firstIndex(of: 0xC3)) + 1
        let server = try HTTPFixture { _ in
            .init(
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    Data(Self.first.utf8), Data(bytes[..<split]), Data(bytes[split...]), Data(Self.end.utf8),
                ], chunkDelay: 0.15)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        store.settings.autoExtractTodos = extract
        let taskID = try #require(await store.queueSummary(id: id, instructions: "Write in English."))
        try await waitUntil { store.summaryDrafts.values[id]?.contains("### Summary") == true }
        #expect(store.meetings[0].summary == "Saved summary")
        #expect(store.meetings[0].todos.isEmpty)
        await store.waitForManagedTask(taskID)
        #expect(store.managedTasks.first { $0.id == taskID }?.state == .completed)
        #expect(store.summaryDrafts.values[id] == nil)
        #expect(store.meetings[0].summary == "### Summary\n\n- [ ] Send résumé 👋")
        #expect(store.meetings[0].todos.count == (extract ? 1 : 0))
        let reopened = MeetingStore(dataDirectory: root)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        #expect(reopened.meeting(id: id)?.summary == store.meetings[0].summary)
        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect((messages.first?["content"] as? String)?.contains("## User Instructions") == true)
        #expect((messages.first?["content"] as? String)?.hasSuffix("Write in English.") == true)
        #expect(store.managedTask(id: taskID)?.summaryInstructions == "Write in English.")
        let transfers = try DataEventJournal.read(directory: store.directory(for: id)).filter { $0.action == .sent }
        #expect(transfers.count == 1)
        let receipt = try #require(transfers.first?.dataFlow)
        #expect(receipt.requestBytes == request.body.count)
        #expect(receipt.responseBytes == (Self.first + Self.second + Self.end).utf8.count)
        #expect(receipt.bodies.contains("notes.md"))
        #expect(receipt.bodies.contains("User Instructions"))
    }

    @Test(arguments: [false, true]) func cancellationAndTruncationKeepSavedSummary(cancel: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(Self.first.utf8), Data(": heartbeat\n\n".utf8)], chunkDelay: 0.4)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        let taskID = try #require(await store.queueSummary(id: id))
        try await waitUntil { store.summaryDrafts.values[id]?.isEmpty == false }
        if cancel { await store.cancelManagedTask(id: taskID) }
        await store.waitForManagedTask(taskID)
        #expect(store.managedTasks.first { $0.id == taskID }?.state == (cancel ? .cancelled : .failed))
        #expect(store.summaryDrafts.values[id] == nil)
        #expect(store.meetings[0].summary == "Saved summary")
        #expect(store.meetings[0].todos.isEmpty)
        #expect(try DataEventJournal.read(directory: store.directory(for: id)).allSatisfy { $0.action != .sent })
    }

    @Test func streamCannotOverwriteSummaryChangedDuringRequest() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(Self.first.utf8), Data(Self.end.utf8)], chunkDelay: 0.2)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        let taskID = try #require(await store.queueSummary(id: id))
        try await waitUntil { store.summaryDrafts.values[id]?.isEmpty == false }
        var changed = store.meetings[0]
        changed.summary = "Changed elsewhere"
        await store.updateMeeting(changed)
        await store.waitForManagedTask(taskID)
        #expect(store.managedTasks.first { $0.id == taskID }?.state == .failed)
        #expect(store.meetings[0].summary == "Changed elsewhere")
        #expect(store.summaryDrafts.values[id] == nil)
        // The provider completed successfully even though newer local text prevented adoption.
        #expect(try DataEventJournal.read(directory: store.directory(for: id)).filter { $0.action == .sent }.count == 1)
    }

    @Test func todoExtractionDefaultsOnAndPersistsOff() throws {
        #expect(AppSettings().autoExtractTodos)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).autoExtractTodos)
        var settings = AppSettings()
        settings.autoExtractTodos = false
        #expect(try !JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).autoExtractTodos)
    }

    @Test(arguments: ["length", "content_filter", "tool_calls"])
    func incompleteJSONResponseKeepsSavedSummary(reason: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(body: "{\"choices\":[{\"finish_reason\":\"\(reason)\",\"message\":{\"content\":\"Partial text\"}}]}")
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        await store.summarize(id: id)
        #expect(store.managedTasks.last?.state == .failed)
        #expect(store.meeting(id: id)?.summary == "Saved summary")
        #expect(store.summaryDrafts.values[id] == nil)
        #expect(server.requests.count == 1)
    }

    @Test func summarySurvivesCallerCancellationAndPlaybackRouteChange() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(Self.first.utf8), Data(Self.second.utf8), Data(Self.end.utf8)], chunkDelay: 0.3)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        let caller = Task { await store.summarize(id: id) }
        try await waitUntil { store.summaryDrafts.values[id]?.isEmpty == false }
        let taskID = try #require(store.managedTasks.last?.id)
        caller.cancel()
        let player = StreamingPlayback(manualRendering: true)
        let updates = AsyncStream<StreamingPlayback.Snapshot>.makeStream()
        player.onUpdate = { updates.continuation.yield($0) }
        player.audioConfigurationChanged()
        var iterator = updates.stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.requiresReload)
        #expect(snapshot.error == nil)
        #expect(store.managedTasks.first { $0.id == taskID }?.state == .running)
        await player.shutdown()
        updates.continuation.finish()
        await caller.value
        #expect(store.managedTasks.first { $0.id == taskID }?.state == .completed)
        #expect(store.meeting(id: id)?.summary == "### Summary\n\n- [ ] Send résumé 👋")
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func inputChangedDuringStreamKeepsSavedSummary(changeTranscript: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [Data(Self.first.utf8), Data(Self.end.utf8)], chunkDelay: 0.3)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = await setup(store, origin: server.origin)
        let taskID = try #require(await store.queueSummary(id: id))
        try await waitUntil { store.summaryDrafts.values[id]?.isEmpty == false }
        var changed = try #require(store.meeting(id: id))
        if changeTranscript {
            changed.transcript = [.init(text: "A later transcript.")]
        }
        else {
            changed.notes += " Additional notes."
        }
        await store.updateMeeting(changed)
        await store.waitForManagedTask(taskID)
        #expect(store.managedTasks.first { $0.id == taskID }?.state == .failed)
        #expect(store.meeting(id: id)?.summary == "Saved summary")
        #expect(store.summaryDrafts.values[id] == nil)
    }
}
