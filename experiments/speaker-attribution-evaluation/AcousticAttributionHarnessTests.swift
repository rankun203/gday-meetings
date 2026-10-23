import CryptoKit
import Darwin
import FluidAudio
import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in experiment adapter. Copies of this file belong in an isolated test target.
struct AcousticAttributionHarnessTests {
    struct Configuration: Decodable, Sendable {
        var tracks: [Track]
        var profilesPath: String
        var excludedMeetingIDs: [UUID]
        var modelRoot: String
        var mode: String
        var repetitions: Int
        var probeCount: Int = 3
        var consistencyCosineFloor: Double = 0.55
        var identityScoreFloor: Double = 0.55
        var minimumMargin: Double = 0.08
        struct Track: Decodable, Sendable {
            var track: String
            var source: String
            var path: String
            var sha256: String
        }
    }
    struct Profiles: Decodable { var profiles: [Person] }
    struct Resource: Encodable, Sendable {
        var wall: Double
        var cpu: Double
        var peakRSSBytes: Int64
        static func now() -> Self {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return .init(
                wall: ProcessInfo.processInfo.systemUptime,
                cpu: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
                peakRSSBytes: Int64(usage.ru_maxrss))
        }
        func elapsed(from start: Self) -> Self {
            .init(wall: wall - start.wall, cpu: cpu - start.cpu, peakRSSBytes: peakRSSBytes)
        }
    }
    struct Score: Encodable, Sendable {
        var personID: UUID
        var score: Double
    }
    struct Vector: Encodable, Sendable {
        var key: String
        var label: String
        var range: VoiceSampleRange
        var role: String
        var embedding: TypedVoiceEmbedding?
        var scores: [Score]
        var personID: UUID?
        var tier: String?
        var score: Double?
        var margin: Double?
        var extraction: Resource?
    }
    struct Cluster: Encodable, Sendable {
        var track: String
        var label: String
        var mixed: Bool
        var reasons: [String]
        var probeKeys: [String]
        var minimumProbeCosine: Double?
    }
    struct Assignment: Encodable, Sendable {
        var track: String
        var label: String
        var start: Double
        var end: Double
        var personID: UUID?
        var tier: String?
        var vectorKey: String?
    }
    struct Pass: Encodable, Sendable {
        var index: Int
        var mode: String
        var scan: Resource
        var incremental: Resource
        var total: Resource
        var audioPreparation: Resource
        var baselineExtractorCalls: Int
        var additionalExtractorCalls: Int
        var reusedVectors: Int
        var vectors: [Vector]
        var clusters: [Cluster]
        var assignments: [Assignment]
    }
    struct Report: Encodable {
        var version = 1
        var sourceRevision: String
        var modelRevision: String
        var configurationFingerprint: String
        var modelLoad: Resource
        var mode: String
        var runs: [Pass]
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        var processorCount = ProcessInfo.processInfo.activeProcessorCount
        var physicalMemory = ProcessInfo.processInfo.physicalMemory
    }

    static func consistency(_ vectors: [Vector], expectedCount: Int, config: Configuration)
        -> (reasons: [String], minimumCosine: Double?)
    {
        var cosines: [Double] = []
        for a in vectors.indices {
            for b in vectors.indices where b > a {
                if let left = vectors[a].embedding, let right = vectors[b].embedding,
                    let score = SpeakerRecognition.similarity(left.values, right.values)
                {
                    cosines.append(score)
                }
            }
        }
        let identities = Set(
            vectors.compactMap { sample -> UUID? in
                guard (sample.score ?? -1) >= config.identityScoreFloor,
                    (sample.margin ?? -1) >= config.minimumMargin
                else { return nil }
                return sample.personID
            })
        var reasons: [String] = []
        if identities.count > 1 { reasons.append("conflicting-reference-identities") }
        if let minimum = cosines.min(), minimum < config.consistencyCosineFloor { reasons.append("low-probe-cohesion") }
        if vectors.count != expectedCount || vectors.contains(where: { $0.embedding == nil }) {
            reasons.append("unavailable-probe-embedding")
        }
        return (reasons, cosines.min())
    }

    static func assignment(_ turn: LocalSpeakerRange, vector: Vector?) -> Assignment {
        .init(
            track: turn.track, label: turn.label, start: turn.start, end: turn.end,
            personID: vector?.personID, tier: vector?.tier, vectorKey: vector?.key)
    }

    private func syntheticVector(person: UUID, values: [Double]) -> Vector {
        .init(
            key: UUID().uuidString, label: "voice_01",
            range: .init(audioFile: "synthetic.wav", source: "system", start: 0, end: 3),
            role: "probe",
            embedding: .init(
                type: .community1SpeechSpan, values: values + Array(repeating: 0, count: 256 - values.count)),
            scores: [], personID: person, tier: "tentative", score: 0.7, margin: 0.2)
    }
    private var syntheticConfiguration: Configuration {
        .init(
            tracks: [], profilesPath: "/synthetic/profiles.json", excludedMeetingIDs: [],
            modelRoot: "/synthetic/models",
            mode: "multi-targeted", repetitions: 1)
    }

    @Test func conflictingIdentitiesTriggerTargetedAttributionEvenWithCohesiveAudio() {
        let vectors = [
            syntheticVector(person: UUID(), values: [1, 0]),
            syntheticVector(person: UUID(), values: [0.99, 0.01]),
        ]
        let result = Self.consistency(vectors, expectedCount: 2, config: syntheticConfiguration)
        #expect(result.reasons == ["conflicting-reference-identities"])
    }

    @Test func homogeneousProbesKeepTheCheaperClusterAttribution() {
        let person = UUID()
        let vectors = [
            syntheticVector(person: person, values: [1, 0]),
            syntheticVector(person: person, values: [0.99, 0.01]),
        ]
        let result = Self.consistency(vectors, expectedCount: 2, config: syntheticConfiguration)
        #expect(result.reasons.isEmpty)
    }

    @Test func aShortTurnWithoutIndependentEvidenceAbstains() {
        let turn = LocalSpeakerRange(track: "track0", label: "voice_01", start: 1, end: 2)
        let attribution = Self.assignment(turn, vector: nil)
        #expect(attribution.personID == nil && attribution.vectorKey == nil)
        #expect(attribution.start == turn.start && attribution.end == turn.end)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_ATTRIBUTION_EXPERIMENT"] == "1"))
    @MainActor func runConfiguredExperiment() async throws {
        let env = ProcessInfo.processInfo.environment
        let configURL = URL(fileURLWithPath: try #require(env["GDAY_ATTRIBUTION_CONFIG"]))
        let destination = URL(fileURLWithPath: try #require(env["GDAY_ATTRIBUTION_OUTPUT"]))
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Configuration.self, from: configData)
        try #require(["baseline", "per-turn", "multi-targeted"].contains(config.mode))
        try #require((1...20).contains(config.repetitions) && (1...12).contains(config.probeCount))
        try #require(!config.tracks.isEmpty && Set(config.tracks.map(\.track)).count == config.tracks.count)
        let profiles = try JSONDecoder().decode(
            Profiles.self, from: Data(contentsOf: URL(fileURLWithPath: config.profilesPath))
        ).profiles
        try #require(!config.excludedMeetingIDs.isEmpty)
        let excluded = Set(config.excludedMeetingIDs)
        let hasLeakedReferences = profiles.flatMap(\.voiceSamples).contains { excluded.contains($0.meetingID) }
        try #require(!hasLeakedReferences)
        for track in config.tracks {
            let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: track.path)))
                .map { String(format: "%02x", $0) }.joined()
            try #require(hash == track.sha256)
        }
        let loading = Resource.now()
        let modelManager = LocalModelManager(root: URL(fileURLWithPath: config.modelRoot))
        let lease = try await modelManager.acquire(.community1)
        defer { modelManager.release(lease) }
        let loadTime = Resource.now().elapsed(from: loading)
        let worker = AttributionExperimentWorker()
        var runs: [Pass] = []
        for index in 0..<config.repetitions {
            runs.append(try await worker.run(config, profiles: profiles, lease: lease, index: index))
        }
        for track in config.tracks {
            let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: track.path)))
                .map { String(format: "%02x", $0) }.joined()
            try #require(hash == track.sha256)
        }
        try #require(Data(contentsOf: configURL) == configData)
        let report = Report(
            sourceRevision: env["GDAY_ATTRIBUTION_SOURCE_REVISION"] ?? "unknown",
            modelRevision: lease.revision,
            configurationFingerprint: VoiceDiscoveryConfiguration.community.pipeline,
            modelLoad: loadTime, mode: config.mode, runs: runs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        print("ATTRIBUTION_EXPERIMENT_COMPLETE mode=\(config.mode) repetitions=\(runs.count)")
    }
}

private actor AttributionExperimentWorker {
    typealias Harness = AcousticAttributionHarnessTests
    private struct Candidate {
        var key: String
        var track: String
        var label: String
        var range: VoiceSampleRange
    }

    private func vector(
        _ candidate: Candidate, embedding: TypedVoiceEmbedding?, role: String,
        profiles: [Person], margin: Double, extraction: Harness.Resource? = nil
    ) -> Harness.Vector {
        let scores =
            embedding.map { embedding in
                profiles.compactMap { person -> Harness.Score? in
                    SpeakerRecognition.match(embedding: embedding, people: [person], threshold: -1, minimumMargin: 0)
                        .map { Harness.Score(personID: $0.personID, score: $0.score) }
                }.sorted {
                    $0.score == $1.score ? $0.personID.uuidString < $1.personID.uuidString : $0.score > $1.score
                }
            } ?? []
        let lead = scores.first.map { $0.score - (scores.dropFirst().first?.score ?? -1) }
        let accepted =
            scores.first.map {
                (lead ?? -1) >= margin && ($0.score >= 0.80 || (scores.count >= 2 && $0.score > 0))
            } ?? false
        return .init(
            key: candidate.key, label: candidate.label, range: candidate.range, role: role, embedding: embedding,
            scores: scores, personID: accepted ? scores.first?.personID : nil,
            tier: accepted ? (scores[0].score >= 0.80 ? "automatic" : "tentative") : nil,
            score: scores.first?.score, margin: lead, extraction: extraction)
    }

    func run(_ config: Harness.Configuration, profiles: [Person], lease: LocalModelLease, index: Int) async throws
        -> Harness.Pass
    {
        let started = Harness.Resource.now()
        let result = try await CommunityDiarizationWorker().run(
            files: config.tracks.map { URL(fileURLWithPath: $0.path) }, lease: lease, recognize: true)
        let scan = Harness.Resource.now().elapsed(from: started)
        let incrementalStart = Harness.Resource.now()
        var vectors: [String: Harness.Vector] = [:]
        var baselineByCluster: [String: String] = [:]
        var candidates: [Candidate] = []
        var baselineCalls = 0
        func clusterKey(_ track: String, _ label: String) -> String { track + ":" + label }
        func candidateKey(_ track: String, _ range: VoiceSampleRange) -> String {
            track + ":" + String(Int((range.start * 16000).rounded())) + ":"
                + String(Int((range.end * 16000).rounded()))
        }
        for speaker in result.speakers {
            guard let range = speaker.voiceSampleRange else { continue }
            baselineCalls += 1
            let candidate = Candidate(
                key: candidateKey(speaker.track, range), track: speaker.track, label: speaker.label, range: range)
            baselineByCluster[clusterKey(speaker.track, speaker.label)] = candidate.key
            vectors[candidate.key] = vector(
                candidate, embedding: speaker.voiceEmbedding, role: "baseline", profiles: profiles,
                margin: config.minimumMargin)
        }
        for turn in result.ranges.sorted(by: { ($0.track, $0.start, $0.end) < ($1.track, $1.start, $1.end) }) {
            guard turn.end - turn.start >= 2,
                !result.ranges.contains(where: {
                    $0.track == turn.track && $0.label != turn.label && $0.start < turn.end && $0.end > turn.start
                }), let trackIndex = Int(turn.track.dropFirst(5)), config.tracks.indices.contains(trackIndex)
            else { continue }
            let input = config.tracks[trackIndex]
            let start = floor(turn.start * 16000) / 16000
            let count = floor(min(10, turn.end - turn.start) * 16000) / 16000
            guard count >= 2 else { continue }
            let range = VoiceSampleRange(
                audioFile: URL(fileURLWithPath: input.path).lastPathComponent, source: input.source,
                start: start, end: start + count)
            candidates.append(
                .init(
                    key: candidateKey(turn.track, range), track: turn.track, label: turn.label, range: range))
        }
        var additionalCalls = 0
        var reusedVectors = 0
        var audioPreparation = Harness.Resource(wall: 0, cpu: 0, peakRSSBytes: 0)
        var clusters: [Harness.Cluster] = []
        let groups = Dictionary(grouping: candidates, by: { clusterKey($0.track, $0.label) })
        if config.mode != "baseline" {
            let extractor = try CommunityVoiceEmbeddingExtractor(models: lease.models)
            for (trackIndex, input) in config.tracks.enumerated() {
                let track = "track\(trackIndex)"
                guard candidates.contains(where: { $0.track == track }) else { continue }
                let preparationStart = Harness.Resource.now()
                let audio = try await AudioPlaybackPreparation.prepare(URL(fileURLWithPath: input.path))
                defer { if audio.temporary { try? FileManager.default.removeItem(at: audio.url) } }
                let (source, _) = try AudioSourceFactory().makeDiskBackedSource(
                    from: audio.url, targetSampleRate: 16000)
                defer { source.cleanup() }
                let preparation = Harness.Resource.now().elapsed(from: preparationStart)
                audioPreparation.wall += preparation.wall
                audioPreparation.cpu += preparation.cpu
                audioPreparation.peakRSSBytes = max(audioPreparation.peakRSSBytes, preparation.peakRSSBytes)
                func extract(_ candidate: Candidate, role: String) async throws {
                    if vectors[candidate.key] != nil {
                        reusedVectors += 1
                        return
                    }
                    let extractionStart = Harness.Resource.now()
                    let offset = Int((candidate.range.start * 16000).rounded())
                    let count = Int(((candidate.range.end - candidate.range.start) * 16000).rounded())
                    guard offset >= 0, count >= 32000, offset + count <= source.sampleCount else { return }
                    var samples = [Float](repeating: 0, count: count)
                    try samples.withUnsafeMutableBufferPointer {
                        try source.copySamples(into: $0.baseAddress!, offset: offset, count: count)
                    }
                    additionalCalls += 1
                    let raw = try? await extractor.extract(samples: samples)
                    let typed = raw.flatMap {
                        TypedVoiceEmbedding.normalizing(
                            type: CommunityVoiceEmbeddingExtractor.embeddingType, values: $0,
                            provenance: "Isolated attribution experiment")
                    }
                    vectors[candidate.key] = vector(
                        candidate, embedding: typed, role: role, profiles: profiles, margin: config.minimumMargin,
                        extraction: Harness.Resource.now().elapsed(from: extractionStart))
                }
                for key in groups.keys.sorted() {
                    let group = groups[key]!
                    guard group[0].track == track else { continue }
                    if config.mode == "per-turn" {
                        for candidate in group { try await extract(candidate, role: "per-turn") }
                        clusters.append(
                            .init(
                                track: track, label: group[0].label, mixed: true, reasons: ["per-turn-policy"],
                                probeKeys: [], minimumProbeCosine: nil))
                        continue
                    }
                    var probes = group.filter { $0.key == baselineByCluster[key] }
                    if probes.isEmpty, let first = group.first { probes = [first] }
                    while probes.count < min(config.probeCount, group.count) {
                        let remaining = group.filter { candidate in !probes.contains(where: { $0.key == candidate.key })
                        }
                        guard
                            let next = remaining.max(by: { left, right in
                                let leftDistance = probes.map { abs($0.range.start - left.range.start) }.min() ?? 0
                                let rightDistance = probes.map { abs($0.range.start - right.range.start) }.min() ?? 0
                                return leftDistance == rightDistance
                                    ? left.range.start > right.range.start : leftDistance < rightDistance
                            })
                        else { break }
                        probes.append(next)
                    }
                    for candidate in probes { try await extract(candidate, role: "probe") }
                    let probeVectors = probes.compactMap { vectors[$0.key] }
                    let assessment = Harness.consistency(probeVectors, expectedCount: probes.count, config: config)
                    let reasons = assessment.reasons
                    let mixed = !reasons.isEmpty
                    if mixed { for candidate in group { try await extract(candidate, role: "targeted-turn") } }
                    clusters.append(
                        .init(
                            track: track, label: group[0].label, mixed: mixed, reasons: reasons,
                            probeKeys: probes.map(\.key), minimumProbeCosine: assessment.minimumCosine))
                }
            }
        }
        let assignments = result.ranges.map { turn -> Harness.Assignment in
            let cluster = clusterKey(turn.track, turn.label)
            let baseline = baselineByCluster[cluster]
            let targeted =
                config.mode == "per-turn"
                || clusters.contains(where: {
                    $0.track == turn.track && $0.label == turn.label && $0.mixed
                })
            let key =
                targeted
                ? candidates.first(where: {
                    $0.track == turn.track && $0.label == turn.label && abs($0.range.start - turn.start) < 0.0001
                })?.key
                : baseline
            return Harness.assignment(turn, vector: key.flatMap { vectors[$0] })
        }
        return .init(
            index: index, mode: config.mode, scan: scan,
            incremental: Harness.Resource.now().elapsed(from: incrementalStart),
            total: Harness.Resource.now().elapsed(from: started),
            audioPreparation: audioPreparation, baselineExtractorCalls: baselineCalls,
            additionalExtractorCalls: additionalCalls, reusedVectors: reusedVectors,
            vectors: vectors.values.sorted { $0.key < $1.key }, clusters: clusters, assignments: assignments)
    }
}
