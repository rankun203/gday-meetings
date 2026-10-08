import CryptoKit
import Foundation

/// Experimental replay adapter around the same causal reducer usable during capture.
/// Local activity bounds publication; embeddings own identity within those bounds.
enum SpeakerObservationConsolidation {
    static let revision = "observation-epochs-direct-capacity-v6"

    static func run(
        _ document: SpeakerEvidenceDocument,
        policy: SpeakerObservationClustering.Configuration,
        representativeLimit: Int, maximumContinuityGap: Double,
        cancellationCheck: () throws -> Void = {}
    ) throws -> SpeakerConsolidation.Analysis {
        guard policy.isValid, representativeLimit > 0,
            maximumContinuityGap.isFinite, maximumContinuityGap >= 0
        else { throw CocoaError(.fileReadCorruptFile) }
        var validated = SpeakerEvidenceDocument()
        for window in document.windows ?? [] { try validated.recordWindow(window) }
        func key(_ source: String, _ local: String) -> String { "\(source.utf8.count):\(source)\(local)" }
        var windows: [String: SpeakerEvidenceWindow] = [:]
        for window in validated.windows ?? [] where window.trustedEnd != nil {
            for local in window.localSpeakerIDs { windows[key(window.source, local)] = window }
        }
        guard
            document.activity.allSatisfy({
                !$0.source.isEmpty && !$0.localSpeakerID.isEmpty && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= 0 && $0.end > $0.start
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        var seen = Set<String>()
        var rejected: [String] = []
        var untrusted: [String] = []
        var outsideWindow: [String] = []
        var unsupportedActivity: [String] = []
        var ambiguous: [String] = []
        var samples: [SpeakerEvidenceSample] = []
        for sample in document.samples.sorted(by: { $0.id < $1.id }) {
            try cancellationCheck()
            guard seen.insert(sample.id).inserted, !sample.id.isEmpty, sample.embedding.isValid,
                sample.start.isFinite, sample.end.isFinite, sample.start >= 0, sample.end > sample.start,
                sample.quality.isFinite, sample.quality > 0
            else {
                rejected.append(sample.id)
                continue
            }
            guard let window = windows[key(sample.source, sample.localSpeakerID)],
                sample.start >= window.publicationStart, sample.end <= window.observedEnd
            else {
                untrusted.append(sample.id)
                outsideWindow.append(sample.id)
                continue
            }
            let spans = document.activity.filter {
                $0.source == sample.source && $0.localSpeakerID == sample.localSpeakerID
                    && $0.start < sample.end && $0.end > sample.start
            }.sorted { $0.start < $1.start }
            var covered = 0.0
            var stop = sample.start
            for span in spans {
                let end = min(sample.end, span.end)
                covered += max(0, end - max(stop, span.start))
                stop = max(stop, end)
            }
            // This establishes observed speech support, not a purity guarantee.
            // Valid embedding excerpts may include short pauses; the persisted
            // schema has no calibrated clean-speech fraction or overlap confidence.
            guard covered > 0 else {
                untrusted.append(sample.id)
                unsupportedActivity.append(sample.id)
                continue
            }
            samples.append(sample)
        }
        samples.sort { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
        var engine = SpeakerObservationClustering(configuration: policy)
        var assignments: [String: String] = [:]
        let trustedActivity = document.activity.compactMap { span -> SpeakerEvidenceActivity? in
            guard let window = windows[key(span.source, span.localSpeakerID)] else { return nil }
            let start = max(span.start, window.publicationStart)
            let end = min(span.end, window.trustedEnd!)
            guard end > start else { return nil }
            return .init(source: span.source, localSpeakerID: span.localSpeakerID, start: start, end: end)
        }
        for sample in samples {
            let recentActivity = trustedActivity.compactMap { span -> SpeakerEvidenceActivity? in
                let start = max(span.start, sample.end - policy.recentSeconds)
                let end = min(span.end, sample.end)
                guard end > start else { return nil }
                return .init(source: span.source, localSpeakerID: span.localSpeakerID, start: start, end: end)
            }
            try engine.recordActivity(recentActivity)
            let window = windows[key(sample.source, sample.localSpeakerID)]!
            let continuity = sample.end <= window.trustedEnd!
            if !continuity {
                // Independent evidence remains useful after the channel capacity
                // boundary; its support must not inherit the expired local epoch.
                let directActivity = document.activity.compactMap { span -> SpeakerEvidenceActivity? in
                    guard let ownWindow = windows[key(span.source, span.localSpeakerID)] else { return nil }
                    let start = max(span.start, sample.start, ownWindow.trustedEnd!)
                    let end = min(span.end, sample.end, ownWindow.observedEnd)
                    guard start < end else { return nil }
                    return .init(source: span.source, localSpeakerID: span.localSpeakerID, start: start, end: end)
                }
                try engine.recordActivity(directActivity, trustLocalContinuity: false)
            }
            _ = try engine.ingest(sample, trustLocalContinuity: continuity, cancellationCheck: cancellationCheck)
            let sequences = (engine.lastRevisions.map(\.sequence) + engine.lastClusterMerges.map(\.sequence)).sorted()
            for sequence in sequences {
                if let update = engine.lastRevisions.first(where: { $0.sequence == sequence }) {
                    assignments[update.sampleID] = update.clusterID
                }
                else if let merge = engine.lastClusterMerges.first(where: { $0.sequence == sequence }) {
                    assignments = assignments.mapValues { $0 == merge.fromClusterID ? merge.toClusterID : $0 }
                }
            }
        }
        ambiguous = samples.filter { assignments[$0.id] == nil }.map(\.id)
        let assignedSamples = Dictionary(grouping: samples.filter { assignments[$0.id] != nil }) {
            assignments[$0.id]!
        }
        // Membership hashes identify a reproducible batch artifact, while reducer
        // IDs remain stable as observations arrive during a live session.
        var publishedIDs: [String: String] = [:]
        let clusters = try engine.clusters.map { cluster -> SpeakerConsolidationResult.Cluster in
            try cancellationCheck()
            let members = assignedSamples[cluster.id] ?? []
            let ids = members.map(\.id).sorted()
            let type = cluster.model
            let fields =
                [
                    revision, type.modelID, type.revision, type.compatibilityVersion,
                    String(type.dimension), type.normalization,
                ] + ids
            let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
            let id = "voice-" + SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
            publishedIDs[cluster.id] = id
            let representatives = try VoiceProfileSelection.selectCancellable(
                members, limit: representativeLimit, cancellationCheck: cancellationCheck)
            return .init(id: id, model: type, sampleIDs: ids, representativeSampleIDs: representatives.map(\.id))
        }
        let establishedIDs = Set(engine.clusters.filter(\.isEstablished).compactMap { publishedIDs[$0.id] })
        assignments = assignments.mapValues { publishedIDs[$0]! }
        let sampleGroups = Dictionary(grouping: samples) { key($0.source, $0.localSpeakerID) }
        let activityGroups = Dictionary(grouping: document.activity) { key($0.source, $0.localSpeakerID) }
        var intervals: [SpeakerConsolidationResult.Interval] = []
        var direct = 0.0
        var inferred = 0.0
        var unresolved = 0.0
        for local in activityGroups.keys.sorted() {
            try cancellationCheck()
            let window = windows[local]
            let localSamples = sampleGroups[local] ?? []
            var activity: [SpeakerEvidenceActivity] = []
            for span in activityGroups[local]!.sorted(by: { $0.start < $1.start }) {
                if let last = activity.last, last.end >= span.start {
                    activity[activity.count - 1].end = max(last.end, span.end)
                }
                else {
                    activity.append(span)
                }
            }
            // Count intervening observed speech, not wall-clock silence. A
            // dormant voice hypothesis survives pauses while continuous speech
            // still requires refreshed identity evidence within the configured bound.
            func speechPosition(_ time: Double) -> Double {
                activity.reduce(0) { $0 + max(0, min(time, $1.end) - $1.start) }
            }
            for span in activity {
                try cancellationCheck()
                let spanPosition = speechPosition(span.start)
                var cuts = [span.start, span.end]
                cuts += [window?.publicationStart, window?.trustedEnd, window?.observedEnd].compactMap { $0 }
                for sample in localSamples {
                    cuts += [sample.start, sample.end]
                    for position in [
                        speechPosition(sample.start) - maximumContinuityGap,
                        speechPosition(sample.end) + maximumContinuityGap,
                    ] {
                        let cut = span.start + position - spanPosition
                        if cut > span.start && cut < span.end { cuts.append(cut) }
                    }
                }
                cuts = Array(Set(cuts.filter { $0 >= span.start && $0 <= span.end })).sorted()
                for (start, end) in zip(cuts, cuts.dropFirst()) {
                    try cancellationCheck()
                    let time = start + (end - start) / 2
                    let trusted = window.map { time >= $0.publicationStart && time < $0.trustedEnd! } ?? false
                    let covering = localSamples.filter { $0.start <= time && time < $0.end }
                    var id: String?
                    let observed = window.map { time >= $0.publicationStart && time < $0.observedEnd } ?? false
                    if observed && !covering.isEmpty {
                        let ids = Set(covering.compactMap { assignments[$0.id] })
                        if ids.count == 1 && covering.allSatisfy({ assignments[$0.id] != nil }) { id = ids.first }
                    }
                    else if trusted {
                        let continuitySamples = localSamples.filter { $0.end <= window!.trustedEnd! }
                        let before = continuitySamples.filter { $0.end <= time }.max { $0.end < $1.end }
                        let after = continuitySamples.filter { $0.start > time }.min { $0.start < $1.start }
                        let neighbors = [before, after].compactMap { $0 }
                        let near = neighbors.filter {
                            min(
                                abs(speechPosition(time) - speechPosition($0.start)),
                                abs(speechPosition(time) - speechPosition($0.end))) <= maximumContinuityGap
                        }
                        let ids = Set(near.compactMap { assignments[$0.id] })
                        // Only evidence within the supported local horizon can
                        // oppose continuation; distant future voices do not veto it.
                        if let before, let after, let left = assignments[before.id],
                            left == assignments[after.id]
                        {
                            // Matching evidence on both sides supports interpolation
                            // through this track's observed speech, even across pauses.
                            id = left
                        }
                        else if after == nil, let before, let previous = assignments[before.id],
                            establishedIDs.contains(previous)
                        {
                            // Established voice epochs resume provisionally on the
                            // same trusted local track. A contrary/ambiguous sample
                            // blocks this branch; window trust still bounds it.
                            id = previous
                        }
                        else if !near.isEmpty && ids.count == 1 && near.allSatisfy({ assignments[$0.id] != nil }) {
                            id = ids.first
                        }
                    }
                    if id == nil {
                        unresolved += end - start
                    }
                    else if covering.isEmpty {
                        inferred += end - start
                    }
                    else {
                        direct += end - start
                    }
                    let value = SpeakerConsolidationResult.Interval(
                        source: span.source, localSpeakerID: span.localSpeakerID, start: start, end: end,
                        clusterID: id,
                        unresolvedReason: id != nil
                            ? nil
                            : (trusted
                                ? "Insufficient or conflicting nearby voice evidence"
                                : "Outside a trusted speaker window"))
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
        }
        intervals.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.localSpeakerID < $1.localSpeakerID
        }
        // Activity can reveal overlap between unsampled portions of two tracks.
        // Do not publish the same anonymous identity on both tracks there, even
        // when clean excerpts outside that overlap were similar enough to merge.
        var conflicts: [Int: [(Double, Double)]] = [:]
        for index in intervals.indices {
            try cancellationCheck()
            let left = intervals[index]
            guard let id = left.clusterID else { continue }
            var other = index + 1
            while other < intervals.count && intervals[other].start < left.end {
                let right = intervals[other]
                if left.source == right.source && left.localSpeakerID != right.localSpeakerID
                    && right.clusterID == id && left.start < right.end
                {
                    let overlap = (max(left.start, right.start), min(left.end, right.end))
                    conflicts[index, default: []].append(overlap)
                    conflicts[other, default: []].append(overlap)
                }
                other += 1
            }
        }
        var resolvedIntervals: [SpeakerConsolidationResult.Interval] = []
        for (index, interval) in intervals.enumerated() {
            let overlap = conflicts[index] ?? []
            let cuts = Array(Set([interval.start, interval.end] + overlap.flatMap { [$0.0, $0.1] })).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst()) {
                var value = interval
                value.start = start
                value.end = end
                if overlap.contains(where: { $0.0 < end && $0.1 > start }) {
                    value.clusterID = nil
                    value.unresolvedReason = "Conflicting simultaneous local activity"
                }
                resolvedIntervals.append(value)
            }
        }
        intervals = resolvedIntervals.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.localSpeakerID < $1.localSpeakerID
        }
        direct = 0
        inferred = 0
        unresolved = 0
        for interval in intervals {
            try cancellationCheck()
            guard interval.clusterID != nil else {
                unresolved += interval.end - interval.start
                continue
            }
            let spans = (sampleGroups[key(interval.source, interval.localSpeakerID)] ?? []).filter {
                assignments[$0.id] == interval.clusterID && $0.start < interval.end && $0.end > interval.start
            }.sorted { $0.start < $1.start }
            var covered = 0.0
            var stop = interval.start
            for sample in spans {
                let end = min(interval.end, sample.end)
                covered += max(0, end - max(stop, sample.start))
                stop = max(stop, end)
            }
            direct += covered
            inferred += interval.end - interval.start - covered
        }
        let units = samples.map { sample -> SpeakerConsolidation.Audit.Unit in
            let window = windows[key(sample.source, sample.localSpeakerID)]!
            return .init(
                source: sample.source, localSpeakerID: sample.localSpeakerID,
                generation: window.generation, trustedStart: sample.start, trustedEnd: sample.end,
                sampleCount: 1, minimumSampleToMeanCosine: 1, meanSampleToMeanCosine: 1)
        }
        return .init(
            result: .init(clusters: clusters, intervals: intervals, rejectedSampleIDs: rejected.sorted()),
            audit: .init(
                method: revision, units: units, cannotLinkUnitPairs: engine.cannotLinkComparisons,
                directSampleSpeakerSeconds: direct, channelInferredSpeakerSeconds: inferred,
                unresolvedSpeakerSeconds: unresolved, untrustedSampleIDs: untrusted.sorted(),
                observationDiagnostics: .init(
                    unsupportedActivitySampleIDs: unsupportedActivity.sorted(),
                    outsideWindowSampleIDs: outsideWindow.sorted(), ambiguousSampleIDs: ambiguous.sorted())))
    }
}
