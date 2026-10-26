import CoreML
import Foundation

// The compiler links the production extractor, decoder, resampler, and type policy.
// Only this CLI boundary is experiment-specific.
struct ServiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ExcerptJob: Codable {
    struct Span: Codable { let start: Double; let end: Double }
    let key: String
    let audioPath: String
    let spans: [Span]
}
struct ExcerptResult: Codable {
    let key: String
    let embedding: TypedVoiceEmbedding?
    let error: String?
    let seconds: Double
}

@main struct EmbeddingExtractor {
    static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            throw ServiceError("Usage: extractor JOBS MODEL_DIRECTORY RESULTS MAX_JOBS (0 means all)")
        }
        AppLogger.mirrorsToConsole = false
        let jobsURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let jobs = try JSONDecoder().decode([ExcerptJob].self, from: Data(contentsOf: jobsURL))
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let limit = Int(CommandLine.arguments[4]) ?? 0
        let completed: Set<String>
        if let data = try? String(contentsOf: resultURL, encoding: .utf8) {
            completed = Set(data.split(separator: "\n").compactMap {
                guard let result = try? JSONDecoder().decode(ExcerptResult.self, from: Data($0.utf8)), result.embedding != nil else { return nil }
                return result.key
            })
        } else { completed = [] }
        let pending = jobs.filter { !completed.contains($0.key) }
        var models: [String: MLModel] = [:]
        for name in ["FBank", "Embedding"] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = name == "FBank" ? .cpuOnly : .all
            models[name] = try MLModel(contentsOf: modelDirectory.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        let extractor = try CommunityVoiceEmbeddingExtractor(models: models)
        if !FileManager.default.fileExists(atPath: resultURL.path) {
            FileManager.default.createFile(atPath: resultURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let output = try FileHandle(forWritingTo: resultURL)
        try output.seekToEnd()
        defer { try? output.close() }
        var currentPath: String?
        var currentSource: DiskBackedAudioSampleSource?
        defer { currentSource?.cleanup() }
        let started = Date()
        for (index, job) in pending.enumerated() {
            if limit > 0 && index >= limit { break }
            let before = Date()
            let result: ExcerptResult
            do {
                var samples: [Float] = []
                if currentPath != job.audioPath {
                    currentSource?.cleanup()
                    currentSource = nil
                    let prepared = try await AudioPlaybackPreparation.prepare(URL(fileURLWithPath: job.audioPath))
                    defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }
                    currentSource = try AudioSourceFactory().makeDiskBackedSource(from: prepared.url, targetSampleRate: 16000).source
                    currentPath = job.audioPath
                }
                guard let source = currentSource else { throw ServiceError("Audio conversion failed.") }
                for span in job.spans {
                    let start = Int((span.start * 16000).rounded())
                    let end = Int((span.end * 16000).rounded())
                    guard start >= 0, end > start, end <= source.sampleCount else {
                        throw ServiceError("The excerpt is outside the decoded audio.")
                    }
                    var part = [Float](repeating: 0, count: end - start)
                    try part.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: start, count: end - start) }
                    samples.append(contentsOf: part)
                }
                let values = try await extractor.extract(samples: samples)
                guard let vector = TypedVoiceEmbedding.normalizing(type: .community1SpeechSpan, values: values, provenance: "Offline global clustering experiment") else {
                    throw ServiceError("The vector could not be normalized.")
                }
                result = ExcerptResult(key: job.key, embedding: vector, error: nil, seconds: Date().timeIntervalSince(before))
            } catch {
                result = ExcerptResult(key: job.key, embedding: nil, error: error.localizedDescription, seconds: Date().timeIntervalSince(before))
            }
            try output.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
            try output.synchronize()
            if index % 25 == 0 || index + 1 == pending.count {
                print("completed=\(index + 1) pending=\(pending.count) elapsed=\(Date().timeIntervalSince(started))")
                fflush(stdout)
            }
        }
    }
}
