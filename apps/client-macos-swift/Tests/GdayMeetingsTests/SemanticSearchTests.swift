import Foundation
import Testing
import Tokenizers

@testable import GdayMeetings

private actor FixtureSemanticEncoder: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID = .granite97M
    var queries: [String] = []
    var passages = 0
    func prepare() {}
    func unload() {}
    func passageParts(_ text: String) -> [String] { [text] }
    func embed(_ text: String, isQuery: Bool) -> [Double] {
        if isQuery {
            queries.append(text)
        }
        else {
            passages += 1
        }
        let similarity = text.contains("speaker passage") ? 0.76 : 0.8
        var vector = Array(repeating: 0.0, count: modelID.dimensions)
        vector[0] = isQuery ? 1 : similarity
        vector[1] = isQuery ? 0 : sqrt(1 - similarity * similarity)
        return vector
    }
}

struct SemanticSearchTests {
    @Test func hundredthResultBoundaryIncludesSpeakerBoostBeforeTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let speaker = MeetingSpeaker(
            label: "Speaker 1", track: "microphone.wav", providerName: "Fixture", personID: person, confirmed: true)
        var meeting = Meeting(title: "Synthetic discussion")
        meeting.speakers = [speaker]
        meeting.transcript = (0..<120).map { position in
            .init(start: Double(position * 60), end: Double(position * 60 + 8), text: "Content passage \(position)")
        }
        meeting.transcript.append(
            .init(start: 7260, end: 7268, text: "speaker passage", speakerID: speaker.id, source: .microphone))
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let encoder = FixtureSemanticEncoder()
        let provider = SemanticSearchProvider(
            id: UUID(), configuration: .init(), directory: root, index: index, encoder: encoder)
        try await provider.updateIndex(meetingID: meeting.id) { _ in }
        let request = ProviderSearchRequest(
            query: "Zora discussion", mode: .semantic, limit: 100, identifiedPeople: [person])
        for try await result in SearchCoordinator(providers: [provider]).search(request) where result.isFinal {
            #expect(result.results.count == 100)
            #expect(result.results.first?.evidence.first?.excerpt == "speaker passage")
        }
        var contentOnly = provider.configuration
        contentOnly.speakerMatchBoost = 0
        let unboosted = SemanticSearchProvider(
            id: provider.id, configuration: contentOnly, directory: root, index: index, encoder: encoder)
        for try await result in SearchCoordinator(providers: [unboosted]).search(request) where result.isFinal {
            #expect(result.results.count == 100)
            #expect(!result.results.flatMap(\.evidence).contains { $0.excerpt == "speaker passage" })
        }
    }

    @Test func boostCountsDistinctSpeakersAndHasNoHardFilter() {
        let first = UUID()
        let second = UUID()
        let score = SpeakerMatchScore(similarity: 0.7, identified: [first, second], speakers: [first], boost: 0.1)
        #expect(abs(score.total - 0.75) < 0.000001)
        #expect(score.matchedPeople == 1)
        #expect(SpeakerMatchScore(similarity: 0.7, identified: [], speakers: [first], boost: 0.1).total == 0.7)
        #expect(SpeakerMatchScore(similarity: 0.7, identified: [first], speakers: [], boost: 0.1).total == 0.7)
        #expect(SpeakerMatchScore(similarity: 0.7, identified: [first], speakers: [first], boost: 0).total == 0.7)
    }

    @Test func rankingBoostPrecedesTopKAndOriginalQueryIsEmbeddedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let speaker = MeetingSpeaker(
            label: "Speaker 1", track: "microphone.wav", providerName: "Fixture", personID: person, confirmed: true)
        var meeting = Meeting(title: "Synthetic discussion")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 8, text: "speaker passage", speakerID: speaker.id, source: .microphone)
        ]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let encoder = FixtureSemanticEncoder()
        let provider = SemanticSearchProvider(
            id: UUID(), configuration: .init(), directory: root, index: index, encoder: encoder)
        try await provider.updateIndex(meetingID: meeting.id) { _ in }
        let query = "What did Zora mention about the discussion?"
        let request = ProviderSearchRequest(query: query, mode: .semantic, limit: 1, identifiedPeople: [person])
        for try await result in provider.search(request) {
            #expect(result.value.results.first?.excerpt == "speaker passage")
            #expect(result.value.results.first?.scoreBreakdown?.matchedPeople == 1)
        }
        let reopened = try SemanticSearchIndex(directory: root, indexDirectory: root)
        var queryVector = Array(repeating: 0.0, count: encoder.modelID.dimensions)
        queryVector[0] = 1
        let persisted = try await reopened.search(vector: queryVector, model: .granite97M, request: request, boost: 0.1)
        #expect(persisted.first?.excerpt == "speaker passage")
        #expect(abs((persisted.first?.scoreBreakdown?.total ?? 0) - 0.86) < 0.000001)
        #expect(await encoder.queries == [query])
        var all = request
        all.limit = 10
        for try await result in SearchCoordinator(providers: [provider]).search(all) where result.isFinal {
            #expect(result.results.count == 2)
            #expect(Set(result.results.flatMap(\.evidence).map(\.id)).count == 2)
        }
        let before = await encoder.passages
        try await provider.updateIndex(meetingID: meeting.id) { _ in }
        #expect(await encoder.passages == before)
        var contentOnly = provider.configuration
        contentOnly.speakerMatchBoost = 0
        let unboosted = SemanticSearchProvider(
            id: provider.id, configuration: contentOnly, directory: root, index: index, encoder: encoder)
        for try await result in unboosted.search(request) {
            #expect(result.value.results.first?.excerpt == "Synthetic discussion")
        }
        var otherModel = Array(repeating: 0.0, count: SemanticModelID.granite311M.dimensions)
        otherModel[0] = 1
        #expect(try await index.search(vector: otherModel, model: .granite311M, request: request, boost: 0.1).isEmpty)
        meeting.title = "Changed discussion"
        try MeetingFolderStorage.write(meeting, directory: root)
        for try await result in provider.search(request) { #expect(result.value.results.isEmpty) }
        try await provider.updateIndex(meetingID: meeting.id) { _ in }
        #expect(await encoder.passages == before + 1)
        // A separate connection sees replacements and removals without a stale vector cache.
        #expect(
            try await reopened.search(vector: queryVector, model: .granite97M, request: request, boost: 0.1).count == 1)
        try await index.remove(meeting.id)
        #expect(
            try await reopened.search(vector: queryVector, model: .granite97M, request: request, boost: 0.1).isEmpty)
    }

    @Test func attendanceAndUnconfirmedLabelsNeverSupplySpeakers() {
        let person = UUID()
        var meeting = Meeting(title: "Synthetic meeting")
        let speaker = MeetingSpeaker(
            label: "Speaker 1", track: "system.wav", providerName: "Fixture", personID: person, confirmed: false)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 5, text: "Zora was mentioned.", speakerID: speaker.id, personID: person)
        ]
        #expect(SemanticSource.windows(meeting).allSatisfy { $0.people.isEmpty })
        meeting.speakers[0].confirmed = true
        #expect(SemanticSource.windows(meeting).first { $0.kind == "transcript" }?.people == [person])
    }

    @Test func nativeTokenizationAndCoreMLMatchConversionProbes() async throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_SEMANTIC_MODEL_FIXTURE_ROOT"] else { return }
        struct Probe: Decodable {
            let ids: [Int]
            let mask: [Int]
            let reference: [Double]
        }
        for model in SemanticModelID.allCases {
            let folder = URL(fileURLWithPath: path).appendingPathComponent(
                model == .granite97M ? "granite-97m-v1" : "granite-311m-v1")
            let probes = try JSONDecoder().decode(
                [Probe].self, from: Data(contentsOf: folder.appendingPathComponent("validation-probes.json")))
            let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = await LocalModelManager(root: root)
            let destination = await manager.modelDirectory(for: model.localID)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: destination)
            let encoder = CoreMLSemanticEmbedding(modelID: model, manager: manager)
            let texts = [
                "Which release date did the team agree on?",
                "Alex proposed Monday. Sam corrected the date to Friday, and the team agreed.",
                "会议最后决定什么时候发布？", "最初建议周一发布，讨论后改为周五。", "Budget review",
                "The team discussed a supplier but did not choose one.",
                String(repeating: "A recorded discussion. ", count: 100),
            ]
            for (text, probe) in zip(texts, probes) {
                let tokens = tokenizer.encode(text: text)
                #expect(tokens == Array(probe.ids.prefix(probe.mask.reduce(0, +))))
                let vector = try await encoder.embed(text, isQuery: true)
                let dot = zip(vector, probe.reference).reduce(0) { $0 + $1.0 * $1.1 }
                #expect(dot > 0.99999)
            }
            await encoder.unload()
        }
    }
}
