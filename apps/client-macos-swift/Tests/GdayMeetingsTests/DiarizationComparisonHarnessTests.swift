import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in experiment entry points. Normal test runs never read private inputs or start inference.
struct DiarizationComparisonHarnessTests {
    private struct Inputs: Decodable {
        var version: Int
        var tracks: [Track]
        struct Track: Decodable {
            var track: String
            var source: String
            var path: String
            var duration: Double
            var sha256: String
        }
    }
    private struct Candidate: Decodable {
        var name: String
        var path: String
    }
    private struct Stages: Encodable {
        var modelRevision: String
        var modelLoadSeconds: Double
        var inferenceSeconds: Double
        var audioSeconds: Double
        var inputHashes: [String: String]
        var extractionEnabled: Bool
        var execution: String
    }
    private struct ProjectionMetrics: Encodable {
        var method: String
        var inputTranscriptSHA256: String
        var sourceRows: Int
        var projectedRows: Int
        var attributedRows: Int
        var unresolvedRows: Int
        var uncertainRows: Int
        var attributedTimedSpans: Int
        var unresolvedTimedSpans: Int
        var projectionSeconds: Double
    }

    private func path(_ key: String) throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[key]))
    }
    private func output() throws -> URL {
        let directory = try path("GDAY_DIARIZATION_BENCHMARK_OUTPUT").standardizedFileURL
        try #require(
            directory.pathComponents.contains(".local"), "Experiment outputs must stay in ignored .local storage.")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func inputs() throws -> Inputs {
        let manifest = try JSONDecoder().decode(
            Inputs.self, from: Data(contentsOf: path("GDAY_DIARIZATION_BENCHMARK_INPUTS")))
        try #require(manifest.version == 1 && !manifest.tracks.isEmpty)
        try #require(Set(manifest.tracks.map(\.track)).count == manifest.tracks.count)
        for (index, track) in manifest.tracks.enumerated() {
            try #require(track.track == "track\(index)")
            try #require(["microphone", "system", "unknown"].contains(track.source))
            try #require(track.duration.isFinite && track.duration > 0)
            try #require(hash(Data(contentsOf: URL(fileURLWithPath: track.path))) == track.sha256)
        }
        return manifest
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_DIARIZATION_BENCHMARK"] == "community"))
    @MainActor func communityOnPreparedInputs() async throws {
        let manifest = try inputs()
        let directory = try output()
        let manager = LocalModelManager(root: try path("GDAY_DIARIZATION_BENCHMARK_MODEL_ROOT"))
        let loading = ProcessInfo.processInfo.systemUptime
        // acquire verifies existing files; this runner never calls a download operation.
        let lease = try await manager.acquire(.community1)
        defer { manager.release(lease) }
        let loaded = ProcessInfo.processInfo.systemUptime
        var result = try await CommunityDiarizationWorker().run(
            files: manifest.tracks.map { URL(fileURLWithPath: $0.path) }, lease: lease, recognize: false)
        let finished = ProcessInfo.processInfo.systemUptime
        result.trackSources = Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.track, $0.source) })
        result.providerName = "Community-1"
        result.audioReferences = manifest.tracks.map {
            .init(trackID: $0.track, source: $0.source, revision: $0.sha256)
        }
        try write(result, to: directory.appendingPathComponent("local-result.json"))
        try write(
            Stages(
                modelRevision: lease.revision, modelLoadSeconds: loaded - loading,
                inferenceSeconds: finished - loaded, audioSeconds: manifest.tracks.reduce(0) { $0 + $1.duration },
                inputHashes: Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.track, $0.sha256) }),
                extractionEnabled: false, execution: "Core ML; existing model manager compute configuration"),
            to: directory.appendingPathComponent("stages.json"))
        #expect(result.ranges.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_DIARIZATION_BENCHMARK"] == "project"))
    func projectCandidatesAgainstOneImmutableTranscript() throws {
        let manifest = try inputs()
        let directory = try output()
        let transcriptURL = try path("GDAY_DIARIZATION_BENCHMARK_TRANSCRIPT")
        let transcriptData = try Data(contentsOf: transcriptURL)
        let decoder = JSONDecoder()
        let rows = try transcriptData.split(separator: 10).map {
            try decoder.decode(TranscriptSegment.self, from: Data($0))
        }
        let tracks = Set(manifest.tracks.map(\.track))
        try #require(!rows.isEmpty && rows.allSatisfy { $0.analysisTrackID.map(tracks.contains) == true })
        try #require(rows.contains { $0.timing?.isValid == true }, "Use a transcript that retains timed spans.")
        let candidates = try decoder.decode(
            [Candidate].self, from: Data(contentsOf: path("GDAY_DIARIZATION_BENCHMARK_RESULTS")))
        try #require(Set(candidates.map(\.name)).count == candidates.count)
        var metrics: [ProjectionMetrics] = []
        for candidate in candidates {
            try #require(
                !candidate.name.isEmpty
                    && candidate.name.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
                    })
            let result = try decoder.decode(
                LocalDiarizationResult.self, from: Data(contentsOf: URL(fileURLWithPath: candidate.path)))
            try #require(result.ranges.allSatisfy { tracks.contains($0.track) })
            var meeting = Meeting()
            meeting.transcript = rows
            let started = ProcessInfo.processInfo.systemUptime
            let projected = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: manifest.tracks.count)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let destination = directory.appendingPathComponent(candidate.name + "-transcript.jsonl")
            try TranscriptStorage.encoded(projected.transcript).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let attributed = projected.transcript.filter { $0.speakerID != nil && $0.sourcePlaceholder != true }
            let unresolved = projected.transcript.filter { $0.speakerID == nil || $0.sourcePlaceholder == true }
            metrics.append(
                .init(
                    method: candidate.name, inputTranscriptSHA256: hash(transcriptData),
                    sourceRows: rows.count, projectedRows: projected.transcript.count,
                    attributedRows: attributed.count, unresolvedRows: unresolved.count,
                    uncertainRows: projected.transcript.filter { $0.associationUncertain == true }.count,
                    attributedTimedSpans: attributed.reduce(0) { $0 + ($1.timing?.spans.count ?? 0) },
                    unresolvedTimedSpans: unresolved.reduce(0) { $0 + ($1.timing?.spans.count ?? 0) },
                    projectionSeconds: elapsed))
        }
        try #require(Data(contentsOf: transcriptURL) == transcriptData)
        try write(metrics, to: directory.appendingPathComponent("projection-metrics.json"))
    }
}
