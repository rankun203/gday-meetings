import Foundation
import Testing

@testable import GdayMeetings

private actor MeasuredProgressEncoder: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID = .granite97M
    func prepare() {}
    func unload() {}
    func passageParts(_ text: String) -> [String] { [text] }
    func embed(_ text: String, isQuery: Bool) -> [Double] {
        var vector = Array(repeating: 0.0, count: modelID.dimensions)
        vector[0] = 1
        return vector
    }
    func embedMeasured(_ text: String, isQuery: Bool) -> SemanticEmbeddingMeasurement {
        .init(vector: embed(text, isQuery: isQuery), processingSeconds: 0.5)
    }
}

struct OperationProgressTests {
    @Test func indexReceiptMeasuresOnlyNewEmbeddingsAndRequiresPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Synthetic discussion")
        meeting.transcript = [.init(start: 0, end: 8, text: "A synthetic passage for indexing.")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let provider = SemanticSearchProvider(
            id: UUID(), configuration: .init(), directory: root,
            index: index, encoder: MeasuredProgressEncoder())
        let first = try #require(
            try await provider.indexWithMeasurement(meetingID: meeting.id, refresh: false) { _ in })
        #expect(first.persisted)
        #expect(first.completed == first.total)
        #expect(first.embeddedCharacters > 0)
        #expect(first.embeddingSeconds > 0)
        #expect(first.remainingCharacters == 0)
        let reused = try #require(
            try await provider.indexWithMeasurement(meetingID: meeting.id, refresh: true) { _ in })
        #expect(reused.persisted)
        #expect(reused.total == first.total)
        #expect(reused.embeddedCharacters == 0)
        #expect(reused.embeddingSeconds == 0)
        #expect(try await provider.indexWithMeasurement(meetingID: meeting.id, refresh: false) { _ in } == nil)
    }

    @Test func voiceProgressAdvancesPhaseAfterDiscoveryFailureAndHidesPausedEstimate() throws {
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: true, exampleIDs: [UUID(), UUID()])
        job.discoveryInputs = [.init(meetingID: UUID(), audioFiles: ["sample.wav"], audioRevisions: [:])]
        job.failures["recording"] = "Synthetic unavailable recording"
        job.progressPhase = "Preparing voice examples"
        job.progressStartedAt = Date(timeIntervalSince1970: 200)
        job.state = .running
        job.completedExampleIDs = [job.exampleIDs[0]]
        job.estimatedRemainingSeconds = 30
        #expect(job.progressDetails.phase == "Analysing voice excerpts")
        #expect(job.progress.contains("1 of 2 voice excerpts analysed"))
        #expect(job.progressDetails.fractionCompleted == 0.5)
        #expect(job.progressDetails.startedAt == job.progressStartedAt)
        #expect(job.progressDetails.estimatedRemainingSeconds == 30)
        job.state = .paused
        #expect(job.progressDetails.estimatedRemainingSeconds == nil)
        job.progressPhase = "Comparing voice examples"
        #expect(job.progressDetails.fractionCompleted == nil)
        #expect(job.progressDetails.estimatedRemainingSeconds == nil)
        let restored = try JSONDecoder().decode(VoicePreparationJob.self, from: JSONEncoder().encode(job))
        #expect(restored.progressPhase == job.progressPhase)
    }

    @Test func rebuildProgressHasNoSpeculativeTimeEstimateForDifferentMeetingSizes() {
        var rebuild = SearchIndexRebuild()
        #expect(rebuild.progressDetails.fractionCompleted == nil)
        rebuild.meetings = [UUID(), UUID(), UUID(), UUID()]
        rebuild.finished = 1
        #expect(rebuild.progressDetails.fractionCompleted == 0.25)
        #expect(rebuild.progressDetails.estimatedRemainingSeconds == nil)
    }
}

@MainActor struct VoiceTransientProgressTests {
    @Test func estimatesDoNotWriteCheckpointsAndSurviveMetadataPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: false, exampleIDs: [UUID()])
        job.state = .running
        job.progressPhase = "Preparing voice examples"
        try #require(library.setJobs([job]))
        let checkpoint = root.appendingPathComponent("voice-library/jobs/\(job.id).json")
        let header = root.appendingPathComponent("voice-library/state.json")
        let original = try Data(contentsOf: checkpoint)
        let revision = VoiceLibraryStore.revision(url: header)
        for value in 1...20 { library.setJobTimeEstimate(Double(value), jobID: job.id) }
        #expect(library.jobs.first?.estimatedRemainingSeconds == 20)
        #expect(try Data(contentsOf: checkpoint) == original)
        #expect(VoiceLibraryStore.revision(url: header) == revision)
        try #require(library.upsert([VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")]))
        #expect(library.jobs.first?.estimatedRemainingSeconds == 20)
        #expect(try Data(contentsOf: checkpoint) == original)
        var paused = try #require(library.jobs.first)
        paused.state = .paused
        try #require(library.setJobs([paused]))
        #expect(library.jobs.first?.estimatedRemainingSeconds == nil)
        let saved = try JSONDecoder().decode(VoicePreparationJob.self, from: Data(contentsOf: checkpoint))
        #expect(saved.state == .paused)
        #expect(saved.estimatedRemainingSeconds == nil)
    }
}
