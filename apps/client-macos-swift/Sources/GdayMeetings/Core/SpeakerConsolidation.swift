import CryptoKit
import Foundation

/// Local channel continuity is usable only within explicit, below-capacity windows.
/// Embeddings associate those units across windows; they do not split a trusted unit.
enum SpeakerConsolidation {
    static let revision = "trusted-channel-mean-complete-link-v1"
    struct Configuration: Codable, Equatable, Sendable {
        var minimumSimilarity = 0.72
        var representativeLimit = 3
        /// Experimental until replay acceptance passes; nil preserves the validated baseline.
        var observationPolicy: SpeakerObservationClustering.Configuration? = nil
        var maximumContinuityGap: Double? = nil
    }
    struct Audit: Codable, Equatable, Sendable {
        struct Unit: Codable, Equatable, Sendable {
            var source: String
            var localSpeakerID: String
            var generation: String
            var trustedStart: Double
            var trustedEnd: Double
            var sampleCount: Int
            var minimumSampleToMeanCosine: Double
            var meanSampleToMeanCosine: Double
        }
        struct ObservationDiagnostics: Codable, Equatable, Sendable {
            var unsupportedActivitySampleIDs: [String]
            var outsideWindowSampleIDs: [String]
            var ambiguousSampleIDs: [String]
        }
        var method = SpeakerConsolidation.revision
        var units: [Unit]
        var cannotLinkUnitPairs: Int
        var directSampleSpeakerSeconds: Double
        var channelInferredSpeakerSeconds: Double
        var unresolvedSpeakerSeconds: Double
        var untrustedSampleIDs: [String]
        var observationDiagnostics: ObservationDiagnostics? = nil
    }
    struct Analysis: Codable, Equatable, Sendable {
        var result: SpeakerConsolidationResult
        var audit: Audit
    }
    private struct Unit {
        var key: String
        var samples: [SpeakerEvidenceSample]
        var vector: [Double]
        var model: EmbeddingType
        var activity: [SpeakerEvidenceActivity]
    }
    private static func key(_ source: String, _ local: String) -> String { "\(source.utf8.count):\(source)\(local)" }

    static func run(
        _ document: SpeakerEvidenceDocument, configuration: Configuration = .init(),
        cancellationCheck: () throws -> Void = {}
    ) throws -> Analysis {
        try cancellationCheck()
        if let policy = configuration.observationPolicy {
            return try SpeakerObservationConsolidation.run(
                document, policy: policy, representativeLimit: configuration.representativeLimit,
                maximumContinuityGap: configuration.maximumContinuityGap ?? 15,
                cancellationCheck: cancellationCheck)
        }
        guard configuration.minimumSimilarity.isFinite, (-1...1).contains(configuration.minimumSimilarity),
            configuration.representativeLimit > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        var validated = SpeakerEvidenceDocument()
        for window in document.windows ?? [] { try validated.recordWindow(window) }
        var trusted: [String: SpeakerEvidenceWindow] = [:]
        for window in validated.windows ?? [] where window.trustedEnd != nil {
            for local in window.localSpeakerIDs { trusted[key(window.source, local)] = window }
        }
        guard
            document.activity.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                    && !$0.source.isEmpty && !$0.localSpeakerID.isEmpty
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        let rawActivity = Dictionary(grouping: document.activity) { key($0.source, $0.localSpeakerID) }
        let activity = rawActivity.mapValues(merged)
        var sampleGroups: [String: [SpeakerEvidenceSample]] = [:]
        var seen = Set<String>()
        var rejected: [String] = []
        var untrusted: [String] = []
        for sample in document.samples.sorted(by: { $0.id < $1.id }) {
            try cancellationCheck()
            guard seen.insert(sample.id).inserted, sample.embedding.isValid, sample.start.isFinite,
                sample.end.isFinite, sample.start >= 0, sample.end > sample.start, sample.quality.isFinite
            else {
                rejected.append(sample.id)
                continue
            }
            let local = key(sample.source, sample.localSpeakerID)
            guard let window = trusted[local], let end = window.trustedEnd,
                sample.start >= window.publicationStart, sample.end <= end
            else {
                untrusted.append(sample.id)
                continue
            }
            sampleGroups[local, default: []].append(sample)
        }
        var units: [Unit] = []
        var unitAudit: [Audit.Unit] = []
        for local in sampleGroups.keys.sorted() {
            try cancellationCheck()
            let samples = sampleGroups[local]!
            guard let first = samples.first, samples.allSatisfy({ $0.model == first.model }) else {
                untrusted += samples.map(\.id)
                continue
            }
            let window = trusted[local]!
            let end = window.trustedEnd!
            let spans = (activity[local] ?? []).compactMap { interval -> SpeakerEvidenceActivity? in
                let start = max(interval.start, window.publicationStart)
                let stop = min(interval.end, end)
                guard stop > start else { return nil }
                return .init(source: interval.source, localSpeakerID: interval.localSpeakerID, start: start, end: stop)
            }
            var mean = [Double](repeating: 0, count: first.vector.count)
            for sample in samples {
                for i in mean.indices { mean[i] += sample.vector[i] / Double(samples.count) }
            }
            guard let normalized = VoiceEmbeddingMath.normalized(mean) else {
                untrusted += samples.map(\.id)
                continue
            }
            let similarities = samples.map { VoiceEmbeddingMath.dot(normalized, $0.vector) }
            units.append(.init(key: local, samples: samples, vector: normalized, model: first.model, activity: spans))
            unitAudit.append(
                .init(
                    source: first.source, localSpeakerID: first.localSpeakerID, generation: window.generation,
                    trustedStart: window.publicationStart, trustedEnd: end, sampleCount: samples.count,
                    minimumSampleToMeanCosine: similarities.min()!,
                    meanSampleToMeanCosine: similarities.reduce(0, +) / Double(similarities.count)))
        }
        var similarities = Array(repeating: Array(repeating: -Double.infinity, count: units.count), count: units.count)
        var cannotLink = 0
        for i in units.indices {
            try cancellationCheck()
            for j in units.indices where j > i {
                if unitAudit[i].source == unitAudit[j].source && overlaps(units[i].activity, units[j].activity) {
                    cannotLink += 1
                    continue
                }
                guard units[i].model == units[j].model else { continue }
                similarities[i][j] = VoiceEmbeddingMath.dot(units[i].vector, units[j].vector)
                similarities[j][i] = similarities[i][j]
            }
        }
        var groups = units.indices.map { [$0] }
        var activeGroups = Array(units.indices)
        while activeGroups.count > 1 {
            try cancellationCheck()
            var best: (Int, Int)?
            var bestSimilarity = -Double.infinity
            for i in activeGroups.indices {
                try cancellationCheck()
                for j in activeGroups.indices where j > i {
                    let similarity = similarities[activeGroups[i]][activeGroups[j]]
                    if similarity >= configuration.minimumSimilarity && similarity > bestSimilarity {
                        best = (i, j)
                        bestSimilarity = similarity
                    }
                }
            }
            guard let (leftIndex, rightIndex) = best else { break }
            let left = activeGroups[leftIndex]
            let right = activeGroups[rightIndex]
            // Complete-link distance to a merged group is the minimum of its
            // two previous distances. Keep leader order to preserve tie breaks.
            for other in activeGroups where other != left && other != right {
                let similarity = min(similarities[left][other], similarities[right][other])
                similarities[left][other] = similarity
                similarities[other][left] = similarity
            }
            groups[left] = (groups[left] + groups[right]).sorted()
            groups[right] = []
            activeGroups.remove(at: rightIndex)
        }
        var assignments: [String: String] = [:]
        let clusters = try activeGroups.map { index -> SpeakerConsolidationResult.Cluster in
            try cancellationCheck()
            let group = groups[index]
            let samples = group.flatMap { units[$0].samples }
            let ids = samples.map(\.id).sorted()
            let type = samples[0].model
            let fields =
                [
                    revision, type.modelID, type.revision, type.compatibilityVersion,
                    String(type.dimension), type.normalization,
                ] + ids
            let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
            let id = "voice-" + SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
            for unit in group { assignments[units[unit].key] = id }
            let examples = try VoiceProfileSelection.selectCancellable(
                samples, limit: configuration.representativeLimit,
                cancellationCheck: cancellationCheck)
            return .init(id: id, model: type, sampleIDs: ids, representativeSampleIDs: examples.map(\.id))
        }
        var intervals: [SpeakerConsolidationResult.Interval] = []
        var direct = 0.0
        var inferred = 0.0
        var unresolved = 0.0
        for local in activity.keys.sorted() {
            try cancellationCheck()
            let window = trusted[local]
            let samples = sampleGroups[local] ?? []
            let sampleSpans = merged(
                samples.map {
                    SpeakerEvidenceActivity(
                        source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
                })
            var sampleIndex = 0
            for (intervalIndex, interval) in activity[local]!.enumerated() {
                if intervalIndex % 128 == 0 { try cancellationCheck() }
                var cuts = [interval.start, interval.end]
                cuts += [window?.publicationStart, window?.trustedEnd].compactMap { $0 }.filter {
                    $0 > interval.start && $0 < interval.end
                }
                cuts = Array(Set(cuts)).sorted()
                for (start, end) in zip(cuts, cuts.dropFirst()) {
                    let time = (start + end) / 2
                    let inside =
                        window.map { time >= $0.publicationStart && time < ($0.trustedEnd ?? $0.publicationStart) }
                        ?? false
                    let id = inside ? assignments[local] : nil
                    if id == nil {
                        unresolved += end - start
                    }
                    else {
                        // Sample boundaries affect the audit, not the assigned
                        // identity. Sweep their union once instead of rescanning
                        // every sample for each published activity interval.
                        while sampleIndex < sampleSpans.count && sampleSpans[sampleIndex].end <= start {
                            sampleIndex += 1
                        }
                        var index = sampleIndex
                        var covered = 0.0
                        while index < sampleSpans.count && sampleSpans[index].start < end {
                            if index % 128 == 0 { try cancellationCheck() }
                            covered += max(0, min(end, sampleSpans[index].end) - max(start, sampleSpans[index].start))
                            index += 1
                        }
                        let duration = end - start
                        let sampled = min(duration, covered)
                        direct += sampled
                        inferred += duration - sampled
                    }
                    let reason =
                        id != nil
                        ? nil
                        : (!inside
                            ? "Outside a trusted speaker window" : "No compatible voice samples for this channel")
                    let value = SpeakerConsolidationResult.Interval(
                        source: interval.source,
                        localSpeakerID: interval.localSpeakerID, start: start, end: end,
                        clusterID: id, unresolvedReason: reason)
                    if let last = intervals.last, last.source == value.source,
                        last.localSpeakerID == value.localSpeakerID,
                        last.end == value.start, last.clusterID == value.clusterID,
                        last.unresolvedReason == value.unresolvedReason
                    {
                        intervals[intervals.count - 1].end = value.end
                    }
                    else {
                        intervals.append(value)
                    }
                }
            }
        }
        intervals.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.localSpeakerID < $1.localSpeakerID
        }
        return Analysis(
            result: .init(clusters: clusters, intervals: intervals, rejectedSampleIDs: rejected.sorted()),
            audit: .init(
                units: unitAudit, cannotLinkUnitPairs: cannotLink,
                directSampleSpeakerSeconds: direct, channelInferredSpeakerSeconds: inferred,
                unresolvedSpeakerSeconds: unresolved, untrustedSampleIDs: untrusted.sorted()))
    }

    private static func merged(_ spans: [SpeakerEvidenceActivity]) -> [SpeakerEvidenceActivity] {
        var result: [SpeakerEvidenceActivity] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= span.start {
                result[result.count - 1].end = max(last.end, span.end)
            }
            else {
                result.append(span)
            }
        }
        return result
    }
    private static func overlaps(_ lhs: [SpeakerEvidenceActivity], _ rhs: [SpeakerEvidenceActivity]) -> Bool {
        var i = 0
        var j = 0
        while i < lhs.count && j < rhs.count {
            if lhs[i].start < rhs[j].end && rhs[j].start < lhs[i].end { return true }
            if lhs[i].end <= rhs[j].end {
                i += 1
            }
            else {
                j += 1
            }
        }
        return false
    }
}
