import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ChatPersistenceTests {
    @Test func contextChatLoadsColdMeetingsBeforeSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"content":"Combined answer"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        configure(store, endpoint: server.origin)
        for title in ["Synthetic planning context", "Synthetic review context"] {
            let id = await store.createMeeting(title: title)
            var meeting = try #require(store.meeting(id: id))
            meeting.notes = title + " notes"
            #expect(await store.updateMeeting(meeting))
        }
        store.clearLoadedMeetingCache()
        #expect(store.meetings.isEmpty)
        #expect(await store.sendContextChat(message: "Compare the notes.") == "Combined answer")
        let request = try #require(server.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let context = try #require(messages.first?["content"] as? String)
        #expect(context.contains("Synthetic planning context notes"))
        #expect(context.contains("Synthetic review context notes"))
        let reopened = MeetingStore(dataDirectory: root)
        #expect(reopened.contextualChats["library"]?.map(\.content) == ["Compare the notes.", "Combined answer"])
    }

    @Test(arguments: [false, true]) func failedIntentSaveDoesNotSendChat(contextual: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"content":"Unexpected answer"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        configure(store, endpoint: server.origin)
        let id = await store.createMeeting(title: "Synthetic meeting")
        store.canonicalWriteHook = { throw ServiceError("Synthetic storage failure") }
        if contextual {
            #expect(await store.sendContextChat(message: "Summarize the notes.") == nil)
        }
        else {
            await store.sendChat(id: id, message: "Summarize the notes.")
        }
        #expect(server.requests.isEmpty)
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.errorMessage?.contains("Synthetic storage failure") == true)
    }

    private func configure(_ store: MeetingStore, endpoint: String) {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = endpoint + "/v1"
        provider.model = "fixture-model"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
    }
}
