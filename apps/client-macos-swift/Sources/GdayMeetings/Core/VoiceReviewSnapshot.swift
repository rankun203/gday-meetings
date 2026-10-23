import Foundation

/// Row identity follows the largest surviving part of an automatic proposal.
/// Membership is authoritative; this session-local mapping changes no decisions.
enum VoiceReviewGroupIdentity {
    static func preserving(_ groups: [VoiceIdentificationGroup], previous: [VoiceIdentificationGroup])
        -> [VoiceIdentificationGroup]
    {
        let owners = Dictionary(
            previous.flatMap { group in group.evidenceExamples.map { ($0.id, group.id) } },
            uniquingKeysWith: { first, _ in first })
        func protected(_ group: VoiceIdentificationGroup) -> Bool {
            group.evidenceExamples.contains { $0.manuallyGrouped || $0.origin == nil }
        }
        let ordered = groups.sorted {
            if protected($0) != protected($1) { return protected($0) }
            return $0.examples.count == $1.examples.count
                ? $0.id.uuidString < $1.id.uuidString : $0.examples.count > $1.examples.count
        }
        var used = Set<UUID>()
        return ordered.map { source in
            var group = source
            if !protected(source) {
                var overlap: [UUID: Int] = [:]
                for example in source.evidenceExamples {
                    if let owner = owners[example.id], !used.contains(owner) { overlap[owner, default: 0] += 1 }
                }
                if let best = overlap.keys.sorted(by: {
                    overlap[$0] == overlap[$1] ? $0.uuidString < $1.uuidString : overlap[$0]! > overlap[$1]!
                }).first {
                    group.id = best
                }
                if used.contains(group.id) {
                    group.id =
                        source.examples.map(\.id).sorted { $0.uuidString < $1.uuidString }.first { !used.contains($0) }
                        ?? VoiceProjectionOrigin.identity(exampleID: source.id, segmentID: source.representativeID)
                }
            }
            used.insert(group.id)
            return group
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// One library state supplies every review count and playback queue. Hidden
/// evidence stays attached to a group so naming covers its original records.
struct VoiceReviewSnapshot: Sendable {
    var revision: Int
    var candidates: [UUID: [VoiceExample]]
    var unnamedGroups: [VoiceIdentificationGroup]

    static func make(
        hydrated allHydrated: [VoiceExample], metadata allMetadata: [VoiceExample], playableIDs: Set<UUID>,
        personIDs: Set<UUID>, revision: Int, policy: VoiceMatchingPolicy = .default,
        preparedGroups: [VoiceIdentificationGroup]? = nil
    ) -> Self {
        let metadata = selectiveEvidence(allMetadata)
        let availableIDs = Set(metadata.map(\.id))
        let hydrated = allHydrated.filter { availableIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        // Unavailable confirmed records remain reference evidence, but cannot
        // become review questions even if their metadata still has a range.
        let ranked = VoiceReviewSelection.rank(hydrated, for: personIDs, policy: policy).mapValues { values in
            values.filter { playableIDs.contains($0.id) }.compactMap { byID[$0.id] }
        }
        let namedAudio = Set(ranked.values.flatMap { $0 }.compactMap(VoiceExactReviewDecisions.Key.init))
        let namedIDs = Set(ranked.values.flatMap { $0 }.map(\.id))
        let unnamedGroups =
            (preparedGroups ?? groups(hydrated: hydrated, metadata: metadata, playableIDs: playableIDs, policy: policy))
            .compactMap {
                source -> VoiceIdentificationGroup? in
                func unnamed(_ example: VoiceExample) -> Bool {
                    availableIDs.contains(example.id) && example.personID == nil && example.namedPersonID == nil
                        && example.suggestedPersonID == nil
                        && !example.excluded && !example.manuallyCleared
                }
                let evidence = source.evidenceExamples.filter(unnamed)
                let visible = source.examples.filter { example in
                    unnamed(example) && !namedIDs.contains(example.id)
                        && VoiceExactReviewDecisions.Key(example).map { !namedAudio.contains($0) } == true
                }
                guard let first = visible.first else { return nil }
                let visibleIDs = Set(visible.map(\.id))
                var group = source
                group.examples = visible
                group.duplicateExamples = evidence.filter { !visibleIDs.contains($0.id) }
                if !visibleIDs.contains(group.representativeID) { group.representativeID = first.id }
                return group
            }
        return Self(revision: revision, candidates: ranked, unnamedGroups: unnamedGroups)
    }

    /// A manually identified speaker with selected recognition evidence does
    /// not need repeated approval of its arbitrary initial excerpt. Keep stored
    /// decisions intact so corrections and later reopening remain reversible.
    static func selectiveEvidence(_ examples: [VoiceExample]) -> [VoiceExample] {
        let selected = Dictionary(
            grouping: examples.filter {
                $0.selectedReference != nil && $0.review == .confirmed && !$0.excluded && !$0.manuallyCleared
            }, by: \.meetingID)
        return examples.filter { example in
            if example.selectedReference != nil && example.review != .confirmed { return false }
            guard example.acceptsSuggestions else { return true }
            return !(selected[example.meetingID] ?? []).contains { reference in
                guard let origin = reference.selectedReference,
                    example.meetingID == origin.meetingID,
                    example.audioRevision == reference.audioRevision,
                    example.namedPersonID == nil || example.namedPersonID == origin.personID
                else { return false }
                // A scan cluster may span multiple transcript identities. Only
                // suppress questions belonging to this exact detected speaker.
                return example.speakerID == origin.speakerID
            }
        }
    }

    static func groups(
        hydrated allHydrated: [VoiceExample], metadata allMetadata: [VoiceExample], playableIDs: Set<UUID>,
        policy: VoiceMatchingPolicy = .default
    ) -> [VoiceIdentificationGroup] {
        let metadata = selectiveEvidence(allMetadata)
        let visibleIDs = Set(metadata.map(\.id))
        let hydrated = allHydrated.filter { visibleIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        var groups = VoiceIdentificationSelection.groups(hydrated, policy: policy).map { source in
            var group = source
            let visible = source.examples.filter { playableIDs.contains($0.id) }
            let hidden = source.duplicateExamples + source.examples.filter { !playableIDs.contains($0.id) }
            group.examples = visible.compactMap { byID[$0.id] }
            group.duplicateExamples = hidden.compactMap { byID[$0.id] }
            if !visible.contains(where: { $0.id == group.representativeID }), let first = visible.first {
                group.representativeID = first.id
            }
            return group
        }
        let included = Set(groups.flatMap(\.evidenceExamples).map(\.id))
        let decisions = VoiceExactReviewDecisions(metadata)
        // Recovery evidence joins its original proposed group as hidden data.
        // A short, invalid, or missing source never creates a reviewable row.
        for example in metadata where !included.contains(example.id) {
            let effective = decisions.applying(to: example)
            guard !effective.manuallyCleared, !effective.excluded else { continue }
            if let index = groups.firstIndex(where: { group in
                group.id == example.groupID || group.evidenceExamples.contains { $0.groupID == example.groupID }
            }) {
                groups[index].duplicateExamples.append(example)
            }
        }
        return groups.filter { !$0.examples.isEmpty }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
