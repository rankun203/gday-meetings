import CryptoKit
import FluidAudio
import Foundation

/// Segmentation and clustering have their own identity. Changing only the review
/// embedding contract can reuse these ranges and prepare new representations.
struct VoiceDiscoveryConfiguration: Codable, Equatable, Sendable {
    var model: String
    var revision: String
    var pipeline: String

    static let community: Self = {
        let descriptor = LocalModelRegistry.descriptor(.community1)
        // Keep the engine revision aligned with Package.resolved when updating
        // FluidAudio; algorithm changes invalidate this tier even with unchanged models.
        return .init(
            model: descriptor.repository, revision: descriptor.revision,
            pipeline: "FluidAudio-21493f8dac5a97e65742e6ff26f42f164c2fda0f|speech-range-v1|"
                + fingerprint(CommunityDiarizationWorker.discoveryConfiguration))
    }()
    /// Include every effective inference option. A dependency update changes the
    /// pinned engine revision above; changed defaults also change these values.
    static func fingerprint(_ config: OfflineDiarizerConfig) -> String {
        let skip: String
        switch config.embedding.skipStrategy {
        case .none: skip = "none"
        case .maskSimilarity(let threshold): skip = "maskSimilarity:\(threshold)"
        }
        let fields: [String: String] = [
            "segmentation.windowDurationSeconds": String(config.segmentation.windowDurationSeconds),
            "segmentation.sampleRate": String(config.segmentation.sampleRate),
            "segmentation.minDurationOn": String(config.segmentation.minDurationOn),
            "segmentation.minDurationOff": String(config.segmentation.minDurationOff),
            "segmentation.stepRatio": String(config.segmentation.stepRatio),
            "segmentation.speechOnsetThreshold": String(config.segmentation.speechOnsetThreshold),
            "segmentation.speechOffsetThreshold": String(config.segmentation.speechOffsetThreshold),
            "embedding.batchSize": String(config.embedding.batchSize),
            "embedding.excludeOverlap": String(config.embedding.excludeOverlap),
            "embedding.minSegmentDurationSeconds": String(config.embedding.minSegmentDurationSeconds),
            "embedding.skipStrategy": skip,
            "clustering.threshold": String(config.clustering.threshold),
            "clustering.warmStartFa": String(config.clustering.warmStartFa),
            "clustering.warmStartFb": String(config.clustering.warmStartFb),
            "clustering.minSpeakers": config.clustering.minSpeakers.map(String.init) ?? "nil",
            "clustering.maxSpeakers": config.clustering.maxSpeakers.map(String.init) ?? "nil",
            "clustering.numSpeakers": config.clustering.numSpeakers.map(String.init) ?? "nil",
            "clustering.constrainedAssignment": String(config.clustering.constrainedAssignment),
            "vbx.maxIterations": String(config.vbx.maxIterations),
            "vbx.convergenceTolerance": String(config.vbx.convergenceTolerance),
            "postProcessing.minGapDurationSeconds": String(config.postProcessing.minGapDurationSeconds),
            "postProcessing.exclusiveSegments": String(config.postProcessing.exclusiveSegments),
            "zeroVoteReembed.enabled": String(config.zeroVoteReembed.enabled),
            "zeroVoteReembed.minDurationSeconds": String(config.zeroVoteReembed.minDurationSeconds),
            "export.embeddingsPath": config.export.embeddingsPath ?? "nil",
            "exposeChunkEmbeddings": String(config.exposeChunkEmbeddings),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A string dictionary always has a JSON representation.
        return String(decoding: try! encoder.encode(fields), as: UTF8.self)
    }

}

/// Derived recording results survive removal of task history. Human decisions
/// remain in the canonical voice library and are never restored from this cache.
actor VoiceDiscoveryCache {
    static let directoryName = "voice-analysis"
    private struct Entry: Codable {
        var version = 3
        var input: VoiceDiscoveryInput
        var configuration: VoiceDiscoveryConfiguration
        var modelRevision: String
        var speakers: [Sample]
        var ranges: [LocalSpeakerRange]?
        var unresolvedRanges: [UnresolvedSpeakerRange]?
        var sampleQualities: [String: VoiceSampleQuality]?
    }

    private struct Sample: Codable {
        var label: String
        var track: String
        var range: VoiceSampleRange
        var revision: String?

        init?(_ speaker: MeetingSpeaker) {
            guard let range = speaker.voiceSampleRange, range.isValid else { return nil }
            label = speaker.label
            track = speaker.track
            self.range = range
            revision = speaker.voiceSampleRevision
        }
        var speaker: MeetingSpeaker {
            var value = MeetingSpeaker(label: label, track: track, providerName: "Community-1")
            value.voiceSampleRange = range
            value.voiceSampleRevision = revision
            return value
        }
    }

    private func url(
        input: VoiceDiscoveryInput, configuration: VoiceDiscoveryConfiguration, directory: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The key excludes generated result identifiers and times.
        struct Key: Encodable {
            var input: VoiceDiscoveryInput
            var configuration: VoiceDiscoveryConfiguration
        }
        let key = try encoder.encode(Key(input: input, configuration: configuration))
        let hash = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let cache = root.appendingPathComponent(Self.directoryName, isDirectory: true)
        guard cache.resolvingSymlinksInPath().path == cache.path else {
            throw ServiceError("The voice analysis cache points outside its recording folder.")
        }
        let path = cache.appendingPathComponent(hash + ".json")
        guard path.resolvingSymlinksInPath().path == path.path else {
            throw ServiceError("The voice analysis cache points outside its recording folder.")
        }
        return path
    }

    func read(
        input: VoiceDiscoveryInput, configuration: VoiceDiscoveryConfiguration, directory: URL
    ) throws -> LocalDiarizationResult? {
        try Task.checkCancellation()
        let path = try url(input: input, configuration: configuration, directory: directory)
        guard let data = try? Data(contentsOf: path), let entry = try? JSONDecoder().decode(Entry.self, from: data),
            entry.version == 3, entry.input == input, entry.configuration == configuration
        else { return nil }
        try Task.checkCancellation()
        return .init(
            modelRevision: entry.modelRevision, ranges: entry.ranges ?? [],
            speakers: entry.speakers.map(\.speaker), unresolvedRanges: entry.unresolvedRanges,
            sampleQualities: entry.sampleQualities)
    }

    func save(
        _ result: LocalDiarizationResult, input: VoiceDiscoveryInput,
        configuration: VoiceDiscoveryConfiguration, directory: URL
    ) throws {
        try Task.checkCancellation()
        let path = try url(input: input, configuration: configuration, directory: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            Entry(
                input: input, configuration: configuration,
                modelRevision: result.modelRevision, speakers: result.speakers.compactMap(Sample.init),
                ranges: result.ranges, unresolvedRanges: result.unresolvedRanges,
                sampleQualities: result.sampleQualities))
        try Task.checkCancellation()
        try data.write(to: path, options: .atomic)
    }
}
