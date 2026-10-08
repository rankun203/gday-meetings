import CryptoKit
import Foundation

/// Causal voice hypotheses: a local track contributes a bounded recent voice
/// profile, but sustained contrary voice evidence starts a new identity epoch.
/// Full samples and assignment history belong in the durable evidence store.
struct SpeakerObservationClustering {
    struct Configuration: Codable, Equatable, Sendable {
        var minimumSimilarity: Double
        var minimumMargin: Double
        var prototypeLimit: Int
        var changeSimilarity: Double
        var changeCoherence: Double
        var recentSeconds: Double
        var recentObservationLimit: Int
        var trackLimit: Int
        init(
            minimumSimilarity: Double = 0.65, minimumMargin: Double = 0.04, prototypeLimit: Int = 12,
            changeSimilarity: Double = 0.45, changeCoherence: Double = 0.55,
            recentSeconds: Double = 30, recentObservationLimit: Int = 256, trackLimit: Int = 256
        ) {
            self.minimumSimilarity = minimumSimilarity
            self.minimumMargin = minimumMargin
            self.prototypeLimit = prototypeLimit
            self.changeSimilarity = changeSimilarity
            self.changeCoherence = changeCoherence
            self.recentSeconds = recentSeconds
            self.recentObservationLimit = recentObservationLimit
            self.trackLimit = trackLimit
        }
        private enum CodingKeys: String, CodingKey {
            case minimumSimilarity, minimumMargin, prototypeLimit, changeSimilarity,
                changeCoherence, recentSeconds, recentObservationLimit, trackLimit
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                minimumSimilarity: try values.decodeIfPresent(Double.self, forKey: .minimumSimilarity) ?? 0.65,
                minimumMargin: try values.decodeIfPresent(Double.self, forKey: .minimumMargin) ?? 0.04,
                prototypeLimit: try values.decodeIfPresent(Int.self, forKey: .prototypeLimit) ?? 12,
                changeSimilarity: try values.decodeIfPresent(Double.self, forKey: .changeSimilarity) ?? 0.45,
                changeCoherence: try values.decodeIfPresent(Double.self, forKey: .changeCoherence) ?? 0.55,
                recentSeconds: try values.decodeIfPresent(Double.self, forKey: .recentSeconds) ?? 30,
                recentObservationLimit: try values.decodeIfPresent(Int.self, forKey: .recentObservationLimit) ?? 256,
                trackLimit: try values.decodeIfPresent(Int.self, forKey: .trackLimit) ?? 256)
        }
        var isValid: Bool {
            [minimumSimilarity, changeSimilarity, changeCoherence].allSatisfy { $0.isFinite && (-1...1).contains($0) }
                && minimumMargin.isFinite && (0...2).contains(minimumMargin) && prototypeLimit > 0
                && recentSeconds.isFinite && recentSeconds > 0 && recentObservationLimit > 0 && trackLimit > 0
        }
    }
    struct Cluster: Sendable {
        var id: String
        var model: EmbeddingType
        var prototypes: [SpeakerEvidenceSample]
        var sampleCount: Int
        var isEstablished: Bool
        fileprivate var profiles: [Profile]
        fileprivate var epochCount: Int
    }
    fileprivate struct Profile: Sendable {
        var epochID: String
        var vector: [Double]
        var updatedAt: Double
    }
    struct AssignmentRevision: Equatable, Sendable {
        var sampleID: String
        var clusterID: String?
        var sequence: Int
    }
    struct ClusterMerge: Equatable, Sendable {
        var fromClusterID: String
        var toClusterID: String
        var sequence: Int
    }
    enum Decision: Equatable, Sendable {
        case assigned(String)
        case ambiguous
    }
    private struct Track: Sendable {
        var epochID: String
        var clusterID: String
        var samples: [SpeakerEvidenceSample]
        var pending: SpeakerEvidenceSample?
        var lastEnd: Double
        var source: String
        var local: String
        var startedAt: Double
    }
    private struct Recent: Sendable {
        var id: String
        var source: String
        var local: String
        var start: Double
        var end: Double
        var clusterID: String?
    }
    let configuration: Configuration
    private(set) var clusters: [Cluster] = []
    private(set) var cannotLinkComparisons = 0
    private(set) var lastRevisions: [AssignmentRevision] = []
    private(set) var lastClusterMerges: [ClusterMerge] = []
    private(set) var revision = 0
    var pendingCount: Int { tracks.values.filter { $0.pending != nil }.count }
    var retainedTrackCount: Int { tracks.count }
    var retainedObservationCount: Int { recent.count }
    private var tracks: [String: Track] = [:]
    private var recent: [Recent] = []
    private struct Activity: Sendable {
        var source: String
        var local: String
        var start: Double
        var end: Double
        var clusterID: String?
    }
    private var recentActivity: [Activity] = []
    private var forbiddenPairs = Set<String>()
    private var watermark = 0.0
    private var evidenceFloor = 0.0

    init(configuration: Configuration = .init()) { self.configuration = configuration }

    /// Activity must already pass the caller's credibility/window checks. It
    /// constrains simultaneous epochs, not whole channel lifetimes.
    mutating func recordActivity(_ intervals: [SpeakerEvidenceActivity]) throws {
        guard
            intervals.allSatisfy({
                !$0.source.isEmpty && !$0.localSpeakerID.isEmpty
                    && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        for interval in intervals {
            watermark = max(watermark, interval.end)
            var value = Activity(
                source: interval.source, local: interval.localSpeakerID,
                start: interval.start, end: interval.end, clusterID: nil)
            let candidates = tracks.values.filter {
                $0.source == interval.source && $0.local == interval.localSpeakerID && $0.startedAt <= interval.start
            }
            if candidates.count == 1 { value.clusterID = candidates[0].clusterID }
            if let index = recentActivity.firstIndex(where: {
                $0.source == value.source && $0.local == value.local && $0.clusterID == value.clusterID
                    && $0.start <= value.end && value.start <= $0.end
            }) {
                recentActivity[index].start = min(recentActivity[index].start, value.start)
                recentActivity[index].end = max(recentActivity[index].end, value.end)
            }
            else {
                recentActivity.append(value)
            }
        }
        evict()
        rememberActivityConstraints()
    }

    mutating func ingest(
        _ sample: SpeakerEvidenceSample, cancellationCheck: () throws -> Void = {}
    ) throws -> Decision {
        try cancellationCheck()
        guard configuration.isValid, sample.embedding.isValid, !sample.id.isEmpty,
            !sample.source.isEmpty, !sample.localSpeakerID.isEmpty,
            sample.start.isFinite, sample.end.isFinite, sample.start >= 0, sample.end > sample.start,
            sample.quality.isFinite, sample.quality > 0, !recent.contains(where: { $0.id == sample.id })
        else { throw CocoaError(.fileReadCorruptFile) }
        // The bounded state is copied transactionally; cancelled extraction work
        // cannot publish a partially updated identity or consume an observation.
        var next = self
        next.lastRevisions = []
        next.lastClusterMerges = []
        next.watermark = max(next.watermark, sample.end)
        next.evict()
        guard sample.start >= next.evidenceFloor else {
            next.record(sample.id, clusterID: nil)
            self = next
            return .ambiguous
        }
        let trackKey = Self.trackKey(sample)
        var assigned: String?
        if var track = next.tracks[trackKey] {
            let mean = Self.mean(track.samples.map(\.vector))
            if VoiceEmbeddingMath.dot(mean, sample.vector) >= configuration.changeSimilarity {
                // A lone low-similarity sample followed by the original voice is
                // an outlier. Keep its identity but never train the profile on it.
                if let pending = track.pending {
                    next.record(pending.id, clusterID: track.clusterID)
                    next.updateRecent(pending.id, clusterID: track.clusterID)
                    next.rememberConstraints(pending, clusterID: track.clusterID)
                    track.pending = nil
                }
                track.samples.append(sample)
                if track.samples.count > configuration.prototypeLimit { track.samples.removeFirst() }
                track.lastEnd = max(track.lastEnd, sample.end)
                next.tracks[trackKey] = track
                try next.updateProfile(track, model: sample.model, cancellationCheck: cancellationCheck)
                assigned = try next.reassociate(trackKey, sample: sample, cancellationCheck: cancellationCheck)
            }
            else if let pending = track.pending,
                VoiceEmbeddingMath.dot(pending.vector, sample.vector) >= configuration.changeCoherence,
                pending.end <= sample.start
            {
                // Confirm a change from its first contrary observation. This splits
                // a reused channel; the preceding epoch remains independently named.
                let created = try next.newTrack(
                    [pending, sample], isChange: true, cancellationCheck: cancellationCheck)
                next.tracks[trackKey] = created
                next.bindActivity(created)
                assigned = created.clusterID
                next.record(pending.id, clusterID: assigned)
                next.updateRecent(pending.id, clusterID: assigned)
                next.rememberConstraints(pending, clusterID: assigned)
            }
            else {
                track.pending = sample
                track.lastEnd = max(track.lastEnd, sample.end)
                next.tracks[trackKey] = track
            }
        }
        else {
            let hadLocalTrack = next.tracks.values.contains {
                $0.source == sample.source && $0.local == sample.localSpeakerID
            }
            let created = try next.newTrack([sample], cancellationCheck: cancellationCheck)
            if !hadLocalTrack {
                // The persistence adapter applies a shell alias only once. A later
                // model change or evicted hot track must not redirect an already
                // resolved historical shell to a different voice.
                next.revision += 1
                next.lastClusterMerges.append(
                    .init(
                        fromClusterID: Self.provisionalClusterID(
                            source: sample.source, localSpeakerID: sample.localSpeakerID),
                        toClusterID: created.clusterID, sequence: next.revision))
            }
            next.tracks[trackKey] = created
            next.bindActivity(created)
            assigned = created.clusterID
        }
        next.recent.append(
            .init(
                id: sample.id, source: sample.source, local: sample.localSpeakerID,
                start: sample.start, end: sample.end, clusterID: assigned))
        next.record(sample.id, clusterID: assigned)
        next.rememberConstraints(sample, clusterID: assigned)
        next.evict()
        self = next
        return assigned.map(Decision.assigned) ?? .ambiguous
    }

    private mutating func newTrack(
        _ samples: [SpeakerEvidenceSample], isChange: Bool = false, cancellationCheck: () throws -> Void
    ) throws -> Track {
        let first = samples[0]
        let id = Self.identity(first)
        let mean = Self.mean(samples.map(\.vector))
        let match = try bestMatch(
            mean, model: first.model, samples: samples, excluding: nil, epochStart: isChange ? first.start : 0,
            cancellationCheck: cancellationCheck)
        let clusterID = match ?? id
        let track = Track(
            epochID: id, clusterID: clusterID, samples: samples, pending: nil,
            lastEnd: samples.map(\.end).max()!, source: first.source, local: first.localSpeakerID,
            startedAt: isChange ? first.start : 0)
        if match == nil {
            clusters.append(
                .init(
                    id: id, model: first.model, prototypes: [], sampleCount: 0,
                    isEstablished: false, profiles: [], epochCount: 0))
        }
        try updateProfile(
            track, model: first.model, newSampleCount: samples.count, cancellationCheck: cancellationCheck)
        return track
    }

    private mutating func updateProfile(
        _ track: Track, model: EmbeddingType, newSampleCount: Int = 1, cancellationCheck: () throws -> Void
    ) throws {
        guard let index = clusters.firstIndex(where: { $0.id == track.clusterID }) else { return }
        let profile = Profile(
            epochID: track.epochID, vector: Self.mean(track.samples.map(\.vector)), updatedAt: track.lastEnd)
        if let existing = clusters[index].profiles.firstIndex(where: { $0.epochID == track.epochID }) {
            clusters[index].profiles[existing] = profile
        }
        else {
            clusters[index].profiles.append(profile)
            clusters[index].epochCount += 1
        }
        clusters[index].profiles.sort {
            $0.updatedAt == $1.updatedAt ? $0.epochID < $1.epochID : $0.updatedAt > $1.updatedAt
        }
        clusters[index].profiles = Array(clusters[index].profiles.prefix(configuration.prototypeLimit))
        let unique = Dictionary(
            (clusters[index].prototypes + track.samples).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        clusters[index].prototypes = try VoiceProfileSelection.selectCancellable(
            Array(unique.values), limit: configuration.prototypeLimit, cancellationCheck: cancellationCheck)
        clusters[index].sampleCount += newSampleCount
        clusters[index].isEstablished = clusters[index].isEstablished || track.samples.count >= 2
    }

    private mutating func reassociate(
        _ key: String, sample: SpeakerEvidenceSample, cancellationCheck: () throws -> Void
    ) throws -> String {
        let track = tracks[key]!
        guard let own = clusters.first(where: { $0.id == track.clusterID }), own.epochCount == 1,
            track.samples.count >= 2,
            let target = try bestMatch(
                Self.mean(track.samples.map(\.vector)), model: sample.model,
                samples: track.samples, excluding: own.id, epochStart: track.startedAt,
                cancellationCheck: cancellationCheck)
        else { return track.clusterID }
        // Only a cluster consisting of this epoch may be aliased. Other epochs
        // already sharing an identity must not be dragged along by one track.
        revision += 1
        lastClusterMerges.append(.init(fromClusterID: own.id, toClusterID: target, sequence: revision))
        for key in tracks.keys where tracks[key]?.clusterID == own.id { tracks[key]?.clusterID = target }
        for index in recent.indices where recent[index].clusterID == own.id { recent[index].clusterID = target }
        for index in recentActivity.indices where recentActivity[index].clusterID == own.id {
            recentActivity[index].clusterID = target
        }
        forbiddenPairs = Set(
            forbiddenPairs.compactMap { value in
                let ids = value.split(separator: ":").map(String.init).map { $0 == own.id ? target : $0 }
                guard ids.count == 2, ids[0] != ids[1] else { return nil }
                return Self.pair(ids[0], ids[1])
            })
        clusters.removeAll { $0.id == own.id }
        try updateProfile(
            tracks[key]!, model: sample.model, newSampleCount: own.sampleCount,
            cancellationCheck: cancellationCheck)
        return target
    }

    private mutating func bestMatch(
        _ vector: [Double], model: EmbeddingType, samples: [SpeakerEvidenceSample], excluding: String?,
        epochStart: Double, cancellationCheck: () throws -> Void
    ) throws -> String? {
        var scores: [(String, Double)] = []
        for cluster in clusters where cluster.model == model && cluster.id != excluding {
            try cancellationCheck()
            let forbidden = excluding.map { forbiddenPairs.contains(Self.pair($0, cluster.id)) } ?? false
            let first = samples[0]
            let activityConflict = recentActivity.contains { own in
                own.source == first.source && own.local == first.localSpeakerID && own.end > epochStart
                    && recentActivity.contains { other in
                        other.source == own.source && other.local != own.local && other.clusterID == cluster.id
                            && max(own.start, epochStart) < other.end && other.start < own.end
                    }
            }
            if forbidden || activityConflict
                || samples.contains(where: { sample in
                    recent.contains { $0.clusterID == cluster.id && Self.cannotLink($0, sample) }
                })
            {
                cannotLinkComparisons += 1
                continue
            }
            let score = VoiceEmbeddingMath.dot(Self.mean(cluster.profiles.map(\.vector)), vector)
            scores.append((cluster.id, score))
        }
        scores.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= configuration.minimumSimilarity,
            scores.count < 2 || best.1 - scores[1].1 >= configuration.minimumMargin
        else { return nil }
        return best.0
    }
    private mutating func bindActivity(_ track: Track) {
        var updated: [Activity] = []
        for var value in recentActivity {
            guard value.source == track.source && value.local == track.local && value.end > track.startedAt else {
                updated.append(value)
                continue
            }
            if value.start < track.startedAt {
                var prefix = value
                prefix.end = track.startedAt
                updated.append(prefix)
                value.start = track.startedAt
            }
            value.clusterID = track.clusterID
            updated.append(value)
        }
        recentActivity = updated
        rememberActivityConstraints()
    }
    private mutating func rememberActivityConstraints() {
        for index in recentActivity.indices {
            let left = recentActivity[index]
            guard let cluster = left.clusterID else { continue }
            for right in recentActivity.dropFirst(index + 1) {
                if let other = right.clusterID, other != cluster, left.source == right.source,
                    left.local != right.local, left.start < right.end, right.start < left.end
                {
                    forbiddenPairs.insert(Self.pair(cluster, other))
                }
            }
        }
    }
    private mutating func rememberConstraints(_ sample: SpeakerEvidenceSample, clusterID: String?) {
        guard let clusterID else { return }
        for previous in recent {
            if let other = previous.clusterID, other != clusterID, Self.cannotLink(previous, sample) {
                forbiddenPairs.insert(Self.pair(other, clusterID))
            }
        }
    }
    private mutating func record(_ id: String, clusterID: String?) {
        revision += 1
        lastRevisions.append(.init(sampleID: id, clusterID: clusterID, sequence: revision))
    }
    private mutating func updateRecent(_ id: String, clusterID: String?) {
        if let index = recent.firstIndex(where: { $0.id == id }) { recent[index].clusterID = clusterID }
    }
    private mutating func evict() {
        evidenceFloor = max(evidenceFloor, watermark - configuration.recentSeconds)
        recent.removeAll { $0.end <= evidenceFloor }
        recentActivity.removeAll { $0.end <= evidenceFloor }
        for index in recentActivity.indices {
            recentActivity[index].start = max(recentActivity[index].start, evidenceFloor)
        }
        if recentActivity.count > configuration.recentObservationLimit {
            recentActivity.sort { $0.end < $1.end }
            let removed = recentActivity.prefix(recentActivity.count - configuration.recentObservationLimit)
            evidenceFloor = max(evidenceFloor, removed.map(\.end).max() ?? evidenceFloor)
            recentActivity.removeAll { $0.end <= evidenceFloor }
        }
        if recent.count > configuration.recentObservationLimit {
            recent.sort { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
            let removed = recent.prefix(recent.count - configuration.recentObservationLimit)
            evidenceFloor = max(evidenceFloor, removed.map(\.end).max() ?? evidenceFloor)
            recent.removeAll { $0.end <= evidenceFloor }
        }
        if tracks.count > configuration.trackLimit {
            let keys = tracks.keys.sorted {
                tracks[$0]!.lastEnd == tracks[$1]!.lastEnd ? $0 < $1 : tracks[$0]!.lastEnd < tracks[$1]!.lastEnd
            }
            for key in keys.prefix(tracks.count - configuration.trackLimit) { tracks.removeValue(forKey: key) }
        }
    }
    private static func mean(_ vectors: [[Double]]) -> [Double] {
        var sum = vectors[0]
        for vector in vectors.dropFirst() { for index in sum.indices { sum[index] += vector[index] } }
        return VoiceEmbeddingMath.normalized(sum) ?? vectors[0]
    }
    /// Anonymous pre-embedding identity; the source/window-local ID must already
    /// be unique across recording windows. This never implies a named Person.
    static func provisionalClusterID(source: String, localSpeakerID: String) -> String {
        let bytes = [source, localSpeakerID].map { "\($0.utf8.count):\($0)" }.joined()
        return "provisional-track-" + SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(_ sample: SpeakerEvidenceSample) -> String {
        let type = sample.model
        let fields = [
            sample.id, type.modelID, type.revision, type.compatibilityVersion, String(type.dimension),
            type.normalization,
        ]
        let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return "observation-" + SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func trackKey(_ sample: SpeakerEvidenceSample) -> String {
        let type = sample.model
        return [
            sample.source, sample.localSpeakerID, type.modelID, type.revision, type.compatibilityVersion,
            String(type.dimension), type.normalization,
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }
    private static func pair(_ left: String, _ right: String) -> String {
        [left, right].sorted().joined(separator: ":")
    }
    private static func cannotLink(_ left: Recent, _ right: SpeakerEvidenceSample) -> Bool {
        left.source == right.source && left.local != right.localSpeakerID && left.start < right.end
            && right.start < left.end
    }
    static func cannotLink(_ left: SpeakerEvidenceSample, _ right: SpeakerEvidenceSample) -> Bool {
        left.source == right.source && left.localSpeakerID != right.localSpeakerID && left.start < right.end
            && right.start < left.end
    }
}
