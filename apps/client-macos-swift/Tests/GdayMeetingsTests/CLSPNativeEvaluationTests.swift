import Foundation
import Testing

@testable import GdayMeetings

/// Explicit local evaluation harness. No library paths or private queries are fixtures.
struct CLSPNativeEvaluationTests {
    private struct Manifest: Decodable {
        struct Query: Decodable {
            let id: String
            let text: String
        }
        struct Clip: Decodable {
            let id: String
            let path: String
            let start: Double
            let duration: Double
        }
        let queries: [Query]
        let clips: [Clip]
        let extraOriginalClips: [Clip]?
    }
    private struct Result: Codable {
        let id: String
        let kind: String
        let vector: [Double]
        let seconds: Double
    }
    private struct Ranking: Encodable {
        let queryID: String
        let clipIDs: [String]
    }

    /// Opt-in decoder parity export; private paths and PCM stay in the supplied local directory.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_CLSP_DECODER_MANIFEST"] != nil))
    func nativeLoaderExportsExplicitLocalRanges() throws {
        let environment = ProcessInfo.processInfo.environment
        let manifestPath = try #require(environment["GDAY_CLSP_DECODER_MANIFEST"])
        let outputPath = try #require(environment["GDAY_CLSP_DECODER_OUTPUT"])
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for clip in manifest.extraOriginalClips ?? [] {
            try #require(
                clip.id.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                })
            let samples = try CLSPAudioLoader.load(
                url: URL(fileURLWithPath: clip.path), start: clip.start, duration: clip.duration)
            try samples.withUnsafeBytes { Data($0) }.write(
                to: output.appendingPathComponent(clip.id + ".f32"), options: .atomic)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_CLSP_EVALUATION_MANIFEST"] != nil))
    func nativeWorkerEvaluatesExplicitLocalDataset() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manifestPath = try #require(environment["GDAY_CLSP_EVALUATION_MANIFEST"])
        let modelRoot = try #require(environment["GDAY_CLSP_EVALUATION_MODEL_ROOT"])
        let outputPath = try #require(environment["GDAY_CLSP_EVALUATION_OUTPUT"])
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let manager = await LocalModelManager(root: URL(fileURLWithPath: modelRoot))
        await manager.refresh([.clsp])
        let worker = CLSPCoreMLWorker(manager: manager)
        var results: [Result] = []
        let output = URL(fileURLWithPath: outputPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            for query in manifest.queries {
                let started = Date()
                let response = try await worker.embed(texts: [query.text])
                let vector = try #require(response.vectors.first)
                results.append(
                    .init(id: query.id, kind: "text", vector: vector, seconds: -started.timeIntervalSinceNow))
                try encoder.encode(results).write(to: output, options: .atomic)
            }
            for clip in manifest.clips + (manifest.extraOriginalClips ?? []) {
                let started = Date()
                let response = try await worker.embed(
                    audio: URL(fileURLWithPath: clip.path), start: clip.start, duration: clip.duration)
                let vector = try #require(response.vectors.first)
                results.append(
                    .init(id: clip.id, kind: "audio", vector: vector, seconds: -started.timeIntervalSinceNow))
                try encoder.encode(results).write(to: output, options: .atomic)
            }
            // Exercise the same persistence and ranked search provider used by the app.
            // The temporary library has generic labels and links only explicitly supplied clips.
            let library = FileManager.default.temporaryDirectory.appendingPathComponent("clsp-evaluation-\(UUID())")
            defer { try? FileManager.default.removeItem(at: library) }
            let provider = try LocalVoiceSearchProvider(directory: library, indexDirectory: library, worker: worker)
            var identities: [UUID: String] = [:]
            let audioResults = Dictionary(
                uniqueKeysWithValues: results.filter { $0.kind == "audio" }.map { ($0.id, $0.vector) })
            for clip in manifest.clips {
                var meeting = Meeting(title: "Evaluation recording")
                meeting.audioFiles = ["audio.wav"]
                try MeetingFolderStorage.write(meeting, directory: library)
                let destination = MeetingFolderStorage.folder(id: meeting.id, directory: library)
                    .appendingPathComponent("audio.wav")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: clip.path), to: destination)
                let (revision, fingerprint) = try VoiceSearchArtifacts.sourceRevision(destination)
                let vector = try #require(audioResults[clip.id])
                try provider.index.persist(
                    .init(
                        meetingID: meeting.id, audioFilename: "audio.wav", sourceRevision: revision,
                        start: clip.start, duration: clip.duration, space: .clsp, vector: vector),
                    fingerprint: fingerprint)
                identities[meeting.id] = clip.id
            }
            try LibraryIndex(directory: library).rebuild()
            var rankings: [Ranking] = []
            for query in manifest.queries {
                var final: ProviderSearchSnapshot?
                for try await event in provider.search(.init(query: query.text, mode: .voice, limit: 150)) {
                    if event.value.isFinal { final = event.value }
                }
                let snapshot = try #require(final)
                #expect(snapshot.total == manifest.clips.count)
                rankings.append(
                    .init(queryID: query.id, clipIDs: snapshot.results.compactMap { identities[$0.meetingID] }))
            }
            try encoder.encode(rankings).write(to: output.appendingPathExtension("rankings.json"), options: .atomic)
        }
        catch {
            await worker.shutdown()
            throw error
        }
        await worker.shutdown()
        #expect(await manager.state(for: .clsp).inUse == 0)
    }
}
