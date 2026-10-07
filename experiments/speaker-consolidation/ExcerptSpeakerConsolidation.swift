import CryptoKit
import Foundation

/// Deterministic complete-link admission, followed by conservative activity reconstruction.
/// Every admitted member must match every existing member. This intentionally avoids
/// transitive chaining; threshold calibration remains encoder and dataset specific.
enum ExcerptSpeakerConsolidation {
    struct Configuration: Codable, Equatable, Sendable {
        var minimumSimilarity: Double = 0.72
        var maximumPropagationSeconds: Double = 15
        var representativeLimit: Int = 3
    }

    static func run(
        _ document: SpeakerEvidenceDocument, configuration: Configuration = .init()
    ) -> SpeakerConsolidationResult {
        runCancellable(document, configuration: configuration, cancellationCheck: {})
    }

    static func runCancellable(
        _ document: SpeakerEvidenceDocument, configuration: Configuration = .init(),
        cancellationCheck: () throws -> Void
    ) rethrows -> SpeakerConsolidationResult {
        try cancellationCheck()
        let ordered = document.samples.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        var seen = Set<String>()
        var rejected: [String] = []
        let samples = ordered.filter { sample in
            let valid =
                sample.start.isFinite && sample.end.isFinite && sample.start >= 0
                && sample.end > sample.start && sample.quality.isFinite
                && sample.embedding.isValid && seen.insert(sample.id).inserted
            if !valid { rejected.append(sample.id) }
            return valid
        }
        let vectors = samples.map { normalized($0.vector)! }
        var groups: [[Int]] = []
        for index in samples.indices {
            try cancellationCheck()
            var best: Int?
            var bestScore = -Double.infinity
            for groupIndex in groups.indices {
                var minimum = Double.infinity
                for member in groups[groupIndex] {
                    if member % 64 == 0 { try cancellationCheck() }
                    let lhs = samples[index]
                    let rhs = samples[member]
                    guard lhs.model == rhs.model, vectors[index].count == vectors[member].count,
                        !(lhs.source == rhs.source && lhs.localSpeakerID != rhs.localSpeakerID
                            && lhs.start < rhs.end && rhs.start < lhs.end)
                    else {
                        minimum = -Double.infinity
                        break
                    }
                    minimum = min(minimum, dot(vectors[index], vectors[member]))
                    if minimum < configuration.minimumSimilarity { break }
                }
                if minimum >= configuration.minimumSimilarity && minimum > bestScore {
                    best = groupIndex
                    bestScore = minimum
                }
            }
            if let best {
                groups[best].append(index)
            }
            else {
                groups.append([index])
            }
        }
        var assignments: [String: String] = [:]
        let clusters = try groups.map { members -> SpeakerConsolidationResult.Cluster in
            try cancellationCheck()
            // Membership changes require a fresh identity, so a regrouped voice cannot inherit
            // a reviewed name merely because its earliest sample stayed in the group.
            let model = samples[members[0]].model
            let identityFields =
                [
                    model.modelID, model.revision, model.compatibilityVersion,
                    String(model.dimension), model.normalization,
                ] + members.map { samples[$0].id }.sorted()
            let identityBytes = identityFields.map { "\($0.utf8.count):\($0)" }.joined()
            let digest = SHA256.hash(data: Data(identityBytes.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "voice-" + digest
            for member in members { assignments[samples[member].id] = id }
            let examples = try VoiceProfileSelection.selectCancellable(
                members.map { samples[$0] }, limit: configuration.representativeLimit,
                cancellationCheck: cancellationCheck)
            return .init(
                id: id, model: samples[members[0]].model,
                sampleIDs: members.map { samples[$0].id }.sorted(), representativeSampleIDs: examples.map(\.id))
        }
        var intervals: [SpeakerConsolidationResult.Interval] = []
        let byLocal = Dictionary(grouping: samples, by: { $0.source + "\u{0}" + $0.localSpeakerID })
        for activity in document.activity.sorted(by: {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.localSpeakerID < $1.localSpeakerID
        })
        where activity.start.isFinite && activity.end.isFinite && activity.start >= 0 && activity.end > activity.start {
            try cancellationCheck()
            let local = byLocal[activity.source + "\u{0}" + activity.localSpeakerID] ?? []
            var cuts = [activity.start, activity.end]
            for sample in local {
                for cut in [
                    sample.start, sample.end,
                    sample.start - configuration.maximumPropagationSeconds,
                    sample.end + configuration.maximumPropagationSeconds,
                ]
                where cut > activity.start && cut < activity.end { cuts.append(cut) }
            }
            cuts = Array(Set(cuts)).sorted()
            for pair in zip(cuts, cuts.dropFirst()) {
                try cancellationCheck()
                let time = (pair.0 + pair.1) / 2
                let containing = local.filter { $0.start <= time && $0.end >= time }
                var clusterID: String?
                var reason = "No nearby voice sample"
                if !containing.isEmpty {
                    let ids = Set(containing.compactMap { assignments[$0.id] })
                    if ids.count == 1 {
                        clusterID = ids.first
                    }
                    else {
                        reason = "Conflicting voice samples"
                    }
                }
                else {
                    let before = local.last(where: { $0.end < time })
                    let after = local.first(where: { $0.start > time })
                    if let before, let after, assignments[before.id] != assignments[after.id] {
                        reason = "Speaker change requires audio review"
                    }
                    else {
                        let nearby = [before, after].compactMap { $0 }.filter {
                            min(abs(time - $0.start), abs(time - $0.end)) <= configuration.maximumPropagationSeconds
                        }
                        clusterID = nearby.first.flatMap { assignments[$0.id] }
                    }
                }
                let value = SpeakerConsolidationResult.Interval(
                    source: activity.source, localSpeakerID: activity.localSpeakerID,
                    start: pair.0, end: pair.1, clusterID: clusterID,
                    unresolvedReason: clusterID == nil ? reason : nil)
                if let last = intervals.last, last.source == value.source,
                    last.localSpeakerID == value.localSpeakerID, last.end == value.start,
                    last.clusterID == value.clusterID, last.unresolvedReason == value.unresolvedReason
                {
                    intervals[intervals.count - 1].end = value.end
                }
                else {
                    intervals.append(value)
                }
            }
        }
        return .init(clusters: clusters, intervals: intervals, rejectedSampleIDs: rejected.sorted())
    }

    static func normalized(_ vector: [Double]) -> [Double]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return vector.map { Double($0) / magnitude }
    }

    static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
