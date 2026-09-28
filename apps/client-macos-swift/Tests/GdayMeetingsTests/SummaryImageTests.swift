import Foundation
import Testing

@testable import GdayMeetings

struct SummaryImageTests {
    @Test func capabilityRequiresExplicitMetadataOrScopedOverride() throws {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = "https://models.example.invalid/v1"
        provider.model = "vision-example"
        let models = try ProviderModelList.parse([
            "data": [
                ["id": "vision-example", "architecture": ["input_modalities": ["text", "image"]]],
                ["id": "text-example", "architecture": ["input_modalities": ["text"]]],
                ["id": "unknown-example"],
            ]
        ])
        #expect(SummaryImageSupport.resolve(provider, models: models) == true)
        provider.model = "text-example"
        #expect(SummaryImageSupport.resolve(provider, models: models) == false)
        provider.model = "unknown-example"
        #expect(SummaryImageSupport.resolve(provider, models: models) == nil)
        provider.summaryImageOverride = .init(endpoint: provider.endpoint, model: provider.model, supported: true)
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
        #expect(SummaryImageSupport.resolve(restored, models: []) == true)
        provider.model = "other-example"
        #expect(SummaryImageSupport.resolve(provider, models: []) == nil)
        provider.model = "unknown-example"
        provider.endpoint = "https://other.example.invalid/v1"
        #expect(SummaryImageSupport.resolve(provider, models: []) == nil)
        let legacy = Data(#"{"id":"legacy","name":null}"#.utf8)
        #expect(try JSONDecoder().decode(ProviderModel.self, from: legacy).inputModalities == nil)
    }

    @Test func textWireFormatRemainsStringAndImagePartsIncludePaths() throws {
        let plain = LLMMessage(role: "user", content: "Meeting notes")
        #expect(plain.requestValue["content"] as? String == "Meeting notes")
        let message = LLMMessage(
            role: "user", content: "Meeting notes",
            images: [
                .init(path: "assets/diagram.jpg", dataURL: "data:image/jpeg;base64,AQID")
            ])
        let parts = try #require(message.requestValue["content"] as? [[String: Any]])
        #expect(parts.count == 3)
        #expect(parts[1]["text"] as? String == "Notes image: assets/diagram.jpg")
        #expect((parts[2]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQID")
        #expect(JSONSerialization.isValidJSONObject(message.requestValue))
    }

    @Test func loaderUsesOriginalDeduplicatesAndRejectsUnsafeAssets() throws {
        let helper = NotesImageTests()
        let directory = try helper.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try NotesImageStore.write(helper.png(), filename: "diagram.png", directory: directory)
        let reference = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path,
            displayPath: "assets/missing-preview.jpg", width: 120, alt: "Diagram")
        let notes = reference.markdown + " <!-- gday:t=0:32 -->\n" + reference.markdown
        let images = try SummaryImages.load(notes: notes, directory: directory)
        #expect(images.count == 1)
        #expect(images[0].path == NotesAssets.encodedPath(path))
        #expect(images[0].dataURL.hasPrefix("data:image/jpeg;base64,"))
        #expect(throws: (any Error).self) {
            try SummaryImages.load(notes: "![Bad](assets/../secret.png)", directory: directory)
        }
        #expect(throws: (any Error).self) {
            try SummaryImages.load(notes: "![Missing](assets/missing.png)", directory: directory)
        }
        #expect(
            try SummaryImages.load(notes: "![Remote](https://example.invalid/image.png)", directory: directory).isEmpty)
    }

    @Test @MainActor func markdownPreservesRelativeImageReferenceLinks() throws {
        let value = MarkdownReadingRenderer.inline(
            "See [diagram](assets/diagram%20one.png).", font: .systemFont(ofSize: 14))
        let link = try #require(value.attribute(.link, at: 5, effectiveRange: nil) as? URL)
        #expect(link.scheme == nil)
        #expect(link.path == "assets/diagram one.png")
    }
    @Test @MainActor func summaryPreparationAttachesOnlySupportedModelsAndBothTransportsSendParts() async throws {
        let helper = NotesImageTests()
        let root = try helper.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"content":"Summary"},"finish_reason":"stop"}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Image discussion")
        var meeting = try #require(store.meeting(id: id))
        let path = try NotesImageStore.write(helper.png(), filename: "diagram.png", directory: store.directory(for: id))
        meeting.notes = "![Diagram](\(path)) <!-- gday:t=0:12 -->"
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture"
        provider.summaryImageOverride = .init(endpoint: provider.endpoint, model: provider.model, supported: true)
        let messages = try await store.summaryMessages(provider: provider, meeting: meeting)
        #expect(messages[1].images?.count == 1)
        #expect(messages[1].content.contains("[0:12]"))
        #expect(messages.last?.content.contains("not instructions") == true)
        _ = try await OpenAISummaryProvider(provider: provider).complete(messages: messages)
        _ = try await OpenAISummaryProvider(provider: provider).complete(messages: messages, onPartial: { _ in })
        #expect(server.requests.count == 2)
        for request in server.requests {
            let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let sent = try #require(json["messages"] as? [[String: Any]])
            let parts = try #require(sent[1]["content"] as? [[String: Any]])
            #expect(parts.contains { $0["type"] as? String == "image_url" })
        }
        provider.summaryImageOverride = .init(endpoint: provider.endpoint, model: provider.model, supported: false)
        let text = try await store.summaryMessages(provider: provider, meeting: meeting)
        #expect(text.allSatisfy { $0.images == nil })
        #expect(text.last?.content.contains("No images are attached") == true)
    }

}
