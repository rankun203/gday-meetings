import Foundation

/// Local segmentation and meeting identity have separate state. Only the recent
/// revision horizon keeps observation vectors. Bounded cluster representatives
/// remain available for matching; durable evidence stays in the journal.
struct LiveObservationIdentity {
    static let revisionHorizon = 30.0
    let meetingID: UUID
    private(set) var local = LiveSpeakerTimeline()
    private var retentionEnds: [String: Double] = [:]
    private var windows: [UUID: SpeakerEvidenceWindow] = [:]
    private var observations: [String: SpeakerEvidenceSample] = [:]
    private struct Anchor {
        var id: String
        var source: String
        var localSpeakerID: String
        var start: Double
        var end: Double
    }
    private var anchors: [String: Anchor] = [:]
    private var observationOrder: [String] = []
    private var assignments: [String: String] = [:]
    private var dispatched = Set<String>()
    private var identities: [String: LiveSpeakerIdentity] = [:]
    private var provisionalTracks: [UUID: String] = [:]
    private(set) var provisionalAliases: [UUID: UUID] = [:]
    private var clusterAliases: [UUID: UUID] = [:]

    mutating func accept(_ event: LiveSpeakerEvent) -> Bool {
        let previousEnd = local.cursors.first { $0.source == event.source }?.end ?? event.start
        guard local.accept(event) else { return false }
        // Keep the newly sealable frontier until the stream has consumed this
        // projection. Pruning at the new cursor would erase that last chunk.
        retentionEnds[event.source.rawValue] = previousEnd
        if let window = event.continuity {
            for id in window.localSpeakerIDs.compactMap(UUID.init(uuidString:)) { windows[id] = window }
        }
        for interval in event.intervals where provisionalTracks[interval.speakerID] == nil {
            guard let localSpeaker = event.speakers.first(where: { $0.id == interval.speakerID }) else { continue }
            let key = SpeakerObservationClustering.provisionalClusterID(
                source: event.source.rawValue, localSpeakerID: interval.speakerID.uuidString)
            provisionalTracks[interval.speakerID] = key
            identities[key] = .init(
                id: MeetingSpeakerConsolidation.identity(
                    meetingID: meetingID, clusterID: key,
                    method: "live-observation-identity-v1"),
                source: event.source, generation: meetingID, slot: identities.count,
                model: localSpeaker.model, revision: localSpeaker.revision,
                meetingLabel: "Speaker \(identities.count + 1)")
        }
        prune()
        return true
    }

    mutating func accept(_ sample: SpeakerEvidenceSample) {
        guard sample.embedding.isValid, sample.end >= sourceTime(sample.source) - Self.revisionHorizon else { return }
        if observations[sample.id] == nil { observationOrder.append(sample.id) }
        observations[sample.id] = sample
        anchors[sample.id] = .init(
            id: sample.id, source: sample.source, localSpeakerID: sample.localSpeakerID,
            start: sample.start, end: sample.end)
    }

    mutating func accept(_ gap: LiveTranscriptGap) {
        local.gaps.append(gap)
        prune()
    }

    mutating func takeReady() -> [SpeakerEvidenceSample] {
        let ready = observationOrder.compactMap { observations[$0] }.filter { sample in
            guard !dispatched.contains(sample.id), let id = UUID(uuidString: sample.localSpeakerID),
                let window = windows[id], window.observedEnd >= sample.end
            else { return false }
            return true
        }
        // Capacity ends channel continuity, not clean acoustic observations.
        // Outside that trust boundary the worker must bypass its local-track prior.
        for sample in ready { dispatched.insert(sample.id) }
        return ready.filter { sample in
            guard let id = UUID(uuidString: sample.localSpeakerID), let window = windows[id],
                sample.start >= window.publicationStart, sample.end <= window.observedEnd
            else { return false }
            let covered = local.intervals.filter { $0.speakerID == id }.reduce(0.0) {
                $0 + max(0, min(sample.end, $1.end) - max(sample.start, $1.start))
            }
            return covered > 0
        }
    }

    func trustedActivity() -> [SpeakerEvidenceActivity] {
        local.intervals.compactMap { interval in
            guard let window = windows[interval.speakerID], let trustedEnd = window.trustedEnd else { return nil }
            let start = max(interval.start, window.publicationStart)
            let end = min(interval.end, trustedEnd)
            guard end > start else { return nil }
            return .init(source: window.source, localSpeakerID: interval.speakerID.uuidString, start: start, end: end)
        }
    }

    func untrustedSampleIDs(_ samples: [SpeakerEvidenceSample]) -> Set<String> {
        Set(samples.filter { !trustedContinuity(local: $0.localSpeakerID, start: $0.start, end: $0.end) }.map(\.id))
    }

    private func trustedContinuity(local: String, start: Double, end: Double) -> Bool {
        guard let id = UUID(uuidString: local), let window = windows[id], let trustedEnd = window.trustedEnd else {
            return false
        }
        return start >= window.publicationStart && end <= trustedEnd
    }

    func untrustedActivity() -> [SpeakerEvidenceActivity] {
        local.intervals.compactMap { interval in
            guard let window = windows[interval.speakerID] else { return nil }
            let start = max(interval.start, window.trustedEnd ?? window.publicationStart, window.publicationStart)
            let end = min(interval.end, window.observedEnd)
            guard end > start else { return nil }
            return .init(source: window.source, localSpeakerID: interval.speakerID.uuidString, start: start, end: end)
        }
    }

    func sample(id: String) -> SpeakerEvidenceSample? { observations[id] }

    mutating func apply(_ result: LiveObservationIdentityUpdate) {
        for merge in result.merges {
            assignments = assignments.mapValues { $0 == merge.fromClusterID ? merge.toClusterID : $0 }
        }
        for change in result.assignments where anchors[change.sampleID] != nil {
            var identity = change.clusterID
            for merge in result.merges where identity == merge.fromClusterID { identity = merge.toClusterID }
            assignments[change.sampleID] = identity
        }
        var claimedAppearances = Set<UUID>()
        for cluster in result.clusters {
            guard let example = cluster.prototypes.first,
                let source = LiveAudioSource(rawValue: example.source)
            else { continue }
            if identities[cluster.id] == nil {
                let provisional = UUID(uuidString: example.localSpeakerID)
                    .flatMap { provisionalTracks[$0] }.flatMap { identities[$0] }
                let appearance = provisional.flatMap {
                    trustedContinuity(local: example.localSpeakerID, start: example.start, end: example.end)
                        && provisionalAliases[$0.id] == nil && claimedAppearances.insert($0.id).inserted ? $0 : nil
                }
                identities[cluster.id] = .init(
                    id: MeetingSpeakerConsolidation.identity(
                        meetingID: meetingID, clusterID: cluster.id,
                        method: "live-observation-identity-v1"),
                    source: source, generation: meetingID, slot: appearance?.slot ?? identities.count,
                    model: cluster.model.modelID,
                    revision: cluster.model.revision, voiceEmbedding: example.embedding,
                    meetingLabel: appearance?.meetingLabel ?? "Speaker \(identities.count + 1)")
            }
        }
        for merge in result.merges {
            let from = MeetingSpeakerConsolidation.identity(
                meetingID: meetingID, clusterID: merge.fromClusterID,
                method: "live-observation-identity-v1")
            let to = MeetingSpeakerConsolidation.identity(
                meetingID: meetingID, clusterID: merge.toClusterID,
                method: "live-observation-identity-v1")
            if clusterAliases[from] == nil && from != to { clusterAliases[from] = to }
        }
        for (sampleID, clusterID) in assignments {
            if let anchor = anchors[sampleID],
                trustedContinuity(local: anchor.localSpeakerID, start: anchor.start, end: anchor.end),
                let local = UUID(uuidString: anchor.localSpeakerID),
                let provisionalKey = provisionalTracks[local], let provisional = identities[provisionalKey],
                let confirmed = identities[clusterID], provisionalAliases[provisional.id] == nil
            {
                provisionalAliases[provisional.id] = confirmed.id
            }
        }
        for (sampleID, clusterID) in assignments {
            guard let sample = observations[sampleID], let source = LiveAudioSource(rawValue: sample.source),
                var identity = identities[clusterID]
            else { continue }
            if identity.source != source && !(identity.additionalSources ?? []).contains(source) {
                identity.additionalSources = (identity.additionalSources ?? []) + [source]
                identities[clusterID] = identity
            }
        }
        let retired = Set(clusterAliases.keys).union(provisionalAliases.keys)
        for key in identities.keys where retired.contains(identities[key]!.id) {
            identities[key]?.voiceEmbedding = nil
        }

    }

    func projection(preserving previous: LiveSpeakerTimeline?) -> LiveSpeakerTimeline {
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = identities.values.sorted {
            $0.slot == $1.slot ? $0.id.uuidString < $1.id.uuidString : $0.slot < $1.slot
        }.map { identity in
            guard let prior = previous?.speakers.first(where: { $0.id == identity.id }), prior.manuallyAssigned else {
                return identity
            }
            var value = identity
            value.voiceEmbedding = prior.voiceEmbedding ?? value.voiceEmbedding
            value.personID = prior.personID
            value.manuallyAssigned = true
            value.manualReviewThrough =
                prior.manualReviewThrough
                ?? Dictionary(uniqueKeysWithValues: (previous?.cursors ?? []).map { ($0.source.rawValue, $0.end) })
            return value
        }
        let metadata = Dictionary(uniqueKeysWithValues: timeline.speakers.map { ($0.id, $0) })
        let candidates = clusterAliases.merging(provisionalAliases) { existing, _ in existing }
        timeline.identityAliases = candidates.filter { source, target in
            guard source != target, metadata[source]?.manuallyAssigned != true,
                metadata[target] != nil
            else { return false }
            let resolved = LiveSpeakerAliases.resolve(source, aliases: candidates)
            return resolved != source && metadata[resolved] != nil
        }
        timeline.cursors = local.cursors.map {
            .init(source: $0.source, generation: meetingID, sequence: $0.sequence, end: $0.end, final: $0.final)
        }
        timeline.gaps = local.gaps
        var proposed: [(localID: UUID, source: LiveAudioSource, interval: LiveSpeakerInterval)] = []
        for activity in local.intervals {
            guard let speaker = local.speakers.first(where: { $0.id == activity.speakerID }),
                let window = windows[activity.speakerID]
            else { continue }
            let trustedEnd = window.trustedEnd ?? window.publicationStart
            let samples = anchors.values.filter {
                $0.localSpeakerID == activity.speakerID.uuidString && $0.source == speaker.source.rawValue
            }
            if let provisional = provisionalTracks[activity.speakerID].flatMap({ identities[$0] }),
                provisionalAliases[provisional.id] == nil
            {
                let start = max(activity.start, window.publicationStart)
                let end = min(activity.end, trustedEnd)
                if end > start {
                    proposed.append(
                        (
                            activity.speakerID, speaker.source,
                            .init(speakerID: provisional.id, start: start, end: end)
                        ))
                }
            }
            var cuts = [activity.start, activity.end, window.publicationStart, trustedEnd, window.observedEnd]
            for sample in samples { cuts += [sample.start, sample.end] }
            cuts = Array(Set(cuts.filter { $0 >= activity.start && $0 <= activity.end })).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst()) {
                let time = (start + end) / 2
                guard time >= window.publicationStart && time < window.observedEnd else { continue }
                let trusted = time < trustedEnd
                if trusted, let shell = provisionalTracks[activity.speakerID].flatMap({ identities[$0] }),
                    provisionalAliases[shell.id] == nil
                {
                    continue
                }
                let covering = samples.filter { $0.start <= time && time < $0.end }
                let neighbors: [Anchor]
                if !covering.isEmpty {
                    neighbors = covering
                }
                else {
                    guard trusted else { continue }
                    neighbors = [
                        samples.filter { $0.end <= time && $0.end <= trustedEnd }.max { $0.end < $1.end },
                        samples.filter { $0.start > time && $0.end <= trustedEnd }.min { $0.start < $1.start },
                    ].compactMap { $0 }
                }
                // A new turn may revise its own start in the hot tail. Within
                // uninterrupted activity, leave conflicting transitions unresolved.
                var supported = neighbors
                if covering.isEmpty, neighbors.count == 2,
                    assignments[neighbors[0].id] != assignments[neighbors[1].id],
                    activity.start >= neighbors[0].end, neighbors[1].start < activity.end
                {
                    supported = [neighbors[1]]
                }
                let labels = Set(supported.compactMap { assignments[$0.id] })
                guard labels.count == 1, supported.allSatisfy({ assignments[$0.id] != nil }),
                    let label = labels.first, let identity = identities[label]
                else { continue }
                proposed.append(
                    (activity.speakerID, speaker.source, .init(speakerID: identity.id, start: start, end: end)))
            }
        }
        // A simultaneous competing local track blocks propagation, even if a
        // matching mistake put both observations into one meeting speaker.
        for item in proposed {
            var cuts = [item.interval.start, item.interval.end]
            let conflicts = proposed.filter {
                $0.source == item.source && $0.localID != item.localID
                    && $0.interval.speakerID == item.interval.speakerID && $0.interval.start < item.interval.end
                    && $0.interval.end > item.interval.start
            }
            for conflict in conflicts {
                cuts += [
                    max(item.interval.start, conflict.interval.start), min(item.interval.end, conflict.interval.end),
                ]
            }
            cuts = Array(Set(cuts)).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst())
            where !conflicts.contains(where: { $0.interval.start < end && $0.interval.end > start }) {
                timeline.intervals.append(
                    .init(
                        source: item.source, speakerID: item.interval.speakerID, start: start, end: end,
                        localTrackID: item.localID))
            }
        }
        if let previous {
            let manualSpeakers = Dictionary(
                uniqueKeysWithValues: timeline.speakers.filter(\.manuallyAssigned).map { ($0.id, $0) })
            var protected: [LiveSpeakerInterval] = []
            for prior in previous.intervals {
                guard let source = prior.source else { continue }
                let ownBoundary = manualSpeakers[prior.speakerID]?.manualReviewThrough?[source.rawValue]
                let targetBoundaries = timeline.intervals.filter {
                    $0.source == prior.source && $0.localTrackID == prior.localTrackID
                        && $0.speakerID != prior.speakerID
                        && $0.start < prior.end && $0.end > prior.start
                }.compactMap { manualSpeakers[$0.speakerID]?.manualReviewThrough?[source.rawValue] }
                guard let boundary = ([ownBoundary].compactMap { $0 } + targetBoundaries).max() else { continue }
                let cursor = retentionEnds[source.rawValue] ?? 0
                var clipped = prior
                clipped.start = max(clipped.start, cursor - Self.revisionHorizon)
                clipped.end = min(clipped.end, boundary)
                if clipped.end > clipped.start { protected.append(clipped) }
            }
            if !protected.isEmpty {
                timeline.intervals =
                    timeline.intervals.flatMap { interval -> [LiveSpeakerInterval] in
                        let overlaps = protected.filter {
                            $0.source == interval.source && $0.localTrackID == interval.localTrackID
                                && $0.start < interval.end && $0.end > interval.start
                        }
                        var cuts = [interval.start, interval.end]
                        for old in overlaps { cuts += [max(interval.start, old.start), min(interval.end, old.end)] }
                        cuts = Array(Set(cuts)).sorted()
                        return zip(cuts, cuts.dropFirst()).compactMap { start, end in
                            guard !overlaps.contains(where: { $0.start < end && $0.end > start }) else { return nil }
                            return .init(
                                source: interval.source, speakerID: interval.speakerID, start: start, end: end,
                                localTrackID: interval.localTrackID)
                        }
                    } + protected
            }
        }
        return timeline
    }

    private func sourceTime(_ source: String) -> Double {
        local.cursors.first { $0.source.rawValue == source }?.end ?? 0
    }

    private mutating func prune() {
        let sourceByID = Dictionary(uniqueKeysWithValues: local.speakers.map { ($0.id, $0.source.rawValue) })
        let clocks = retentionEnds
        local.intervals.removeAll { interval in
            interval.end < (clocks[sourceByID[interval.speakerID] ?? ""] ?? 0) - Self.revisionHorizon
        }
        local.gaps.removeAll { $0.end < (clocks[$0.source.rawValue] ?? 0) - Self.revisionHorizon }
        observations = observations.filter { $0.value.end >= (clocks[$0.value.source] ?? 0) - Self.revisionHorizon }
        observationOrder.removeAll { observations[$0] == nil }
        // Vector-free dormant anchors survive silence within a current window.
        let grouped = Dictionary(grouping: anchors.values) { $0.source + ":" + $0.localSpeakerID }
        let retained = Set(
            grouped.values.flatMap { values -> [String] in
                let cutoff = (clocks[values[0].source] ?? 0) - Self.revisionHorizon
                let recent = values.filter { $0.end >= cutoff }.map(\.id)
                let preceding = values.filter { $0.end < cutoff }.max { $0.end < $1.end }?.id
                return recent + [preceding].compactMap { $0 }
            })
        anchors = anchors.filter { retained.contains($0.key) }
        assignments = assignments.filter { anchors[$0.key] != nil }
        dispatched.formIntersection(observations.keys)
        let active = Set(local.intervals.map(\.speakerID)).union(
            observations.values.compactMap { UUID(uuidString: $0.localSpeakerID) })
        windows = windows.filter {
            active.contains($0.key) || $0.value.observedEnd >= (clocks[$0.value.source] ?? 0) - Self.revisionHorizon
        }
        local.speakers.removeAll { !windows.keys.contains($0.id) }
        anchors = anchors.filter { UUID(uuidString: $0.value.localSpeakerID).map { windows[$0] != nil } ?? false }
        assignments = assignments.filter { anchors[$0.key] != nil }
    }

}

struct LiveObservationIdentityUpdate: Sendable {
    struct Assignment: Sendable {
        var sampleID: String
        var clusterID: String?
    }
    struct Cluster: Sendable {
        var id: String
        var model: EmbeddingType
        var prototypes: [SpeakerEvidenceSample]
    }
    struct Merge: Sendable {
        var fromClusterID: String
        var toClusterID: String
    }
    var assignments: [Assignment]
    var clusters: [Cluster]
    var merges: [Merge] = []
}

actor LiveObservationIdentityWorker {
    private var engine: SpeakerObservationClustering
    init(configuration: SpeakerObservationClustering.Configuration) { engine = .init(configuration: configuration) }
    func ingest(
        _ samples: [SpeakerEvidenceSample], activity: [SpeakerEvidenceActivity] = [],
        untrustedActivity: [SpeakerEvidenceActivity] = [], untrustedSampleIDs: Set<String> = []
    ) throws
        -> LiveObservationIdentityUpdate
    {
        try engine.recordActivity(activity)
        try engine.recordActivity(untrustedActivity, trustLocalContinuity: false)
        var changes: [LiveObservationIdentityUpdate.Assignment] = []
        var merges: [LiveObservationIdentityUpdate.Merge] = []
        for sample in samples {
            try Task.checkCancellation()
            _ = try engine.ingest(
                sample, trustLocalContinuity: !untrustedSampleIDs.contains(sample.id),
                cancellationCheck: { try Task.checkCancellation() })
            merges += engine.lastClusterMerges.map {
                .init(fromClusterID: $0.fromClusterID, toClusterID: $0.toClusterID)
            }
            changes += engine.lastRevisions.map { .init(sampleID: $0.sampleID, clusterID: $0.clusterID) }
        }
        let clusters = try engine.clusters.map { cluster in
            LiveObservationIdentityUpdate.Cluster(
                id: cluster.id, model: cluster.model,
                prototypes: try VoiceProfileSelection.selectCancellable(
                    cluster.prototypes, limit: 3, cancellationCheck: { try Task.checkCancellation() }))
        }
        return .init(assignments: changes, clusters: clusters, merges: merges)
    }
}

struct LiveObservationReviewAssignment: Sendable {
    var sample: SpeakerEvidenceSample
    var meetingSpeakerID: UUID?
}
