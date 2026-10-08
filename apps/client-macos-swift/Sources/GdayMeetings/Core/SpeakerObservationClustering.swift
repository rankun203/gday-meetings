import CryptoKit
import Foundation

/// Causal anonymous identity reducer. The caller supplies already purity-gated,
/// compatible observations in arrival order; no channel identifier carries identity.
/// This experimental reducer never enrolls a Person or rewrites prior assignments.
struct SpeakerObservationClustering {
    struct Configuration: Codable, Equatable, Sendable {
        var minimumSimilarity = 0.72
        var minimumMargin = 0.08
        var prototypeLimit = 12

        var isValid: Bool {
            minimumSimilarity.isFinite && (-1...1).contains(minimumSimilarity)
                && minimumMargin.isFinite && (0...2).contains(minimumMargin) && prototypeLimit > 0
        }
    }
    struct Cluster: Sendable {
        var id: String
        var model: EmbeddingType
        var samples: [SpeakerEvidenceSample]
        var prototypes: [SpeakerEvidenceSample]
    }
    enum Decision: Equatable, Sendable {
        case assigned(String)
        case ambiguous
    }
    let configuration: Configuration
    private(set) var clusters: [Cluster] = []
    private(set) var cannotLinkComparisons = 0
    private var seen = Set<String>()

    init(configuration: Configuration = .init()) { self.configuration = configuration }

    mutating func ingest(
        _ sample: SpeakerEvidenceSample, cancellationCheck: () throws -> Void = {}
    ) throws -> Decision {
        try cancellationCheck()
        guard configuration.isValid, sample.embedding.isValid, !sample.id.isEmpty,
            !sample.source.isEmpty, !sample.localSpeakerID.isEmpty,
            sample.start.isFinite, sample.end.isFinite, sample.start >= 0, sample.end > sample.start,
            sample.quality.isFinite, sample.quality > 0, !seen.contains(sample.id)
        else { throw CocoaError(.fileReadCorruptFile) }
        var candidates: [(index: Int, score: Double)] = []
        var blocked = 0
        for index in clusters.indices {
            try cancellationCheck()
            let cluster = clusters[index]
            guard cluster.model == sample.model else { continue }
            // Keep temporal constraints for every observation, even when its vector
            // is no longer one of the bounded matching representatives.
            if cluster.samples.contains(where: { Self.cannotLink($0, sample) }) {
                blocked += 1
                continue
            }
            // Requiring agreement with every retained representative and the
            // immutable first observation prevents simple nearest-neighbor chains.
            let score = ([cluster.samples[0]] + cluster.prototypes).map {
                VoiceEmbeddingMath.dot($0.vector, sample.vector)
            }.min()!
            candidates.append((index, score))
        }
        candidates.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let decision: Decision
        if let best = candidates.first, best.score >= configuration.minimumSimilarity,
            candidates.count > 1 && best.score - candidates[1].score < configuration.minimumMargin
        {
            decision = .ambiguous
        }
        else if let best = candidates.first, best.score >= configuration.minimumSimilarity {
            let samples = clusters[best.index].samples + [sample]
            let prototypes = try VoiceProfileSelection.selectCancellable(
                clusters[best.index].prototypes + [sample], limit: configuration.prototypeLimit,
                cancellationCheck: cancellationCheck)
            clusters[best.index].samples = samples
            clusters[best.index].prototypes = prototypes
            decision = .assigned(clusters[best.index].id)
        }
        else {
            // IDs survive future evidence additions in this reducer. Publication
            // adds a meeting namespace rather than treating these as Person IDs.
            let type = sample.model
            let fields = [
                sample.id, type.modelID, type.revision, type.compatibilityVersion,
                String(type.dimension), type.normalization,
            ]
            let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
            let id = "observation-" + SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
            clusters.append(.init(id: id, model: sample.model, samples: [sample], prototypes: [sample]))
            decision = .assigned(id)
        }
        seen.insert(sample.id)
        cannotLinkComparisons += blocked
        return decision
    }

    static func cannotLink(_ left: SpeakerEvidenceSample, _ right: SpeakerEvidenceSample) -> Bool {
        left.source == right.source && left.localSpeakerID != right.localSpeakerID
            && left.start < right.end && right.start < left.end
    }
}
