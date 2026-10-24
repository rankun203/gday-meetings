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
    var coveredExampleIDs: [UUID: Set<UUID>] = [:]

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
        let evaluation = VoiceReviewSelection.evaluate(hydrated, for: personIDs, policy: policy)
        let ranked = evaluation.candidates.mapValues { values in
            values.filter { playableIDs.contains($0.id) }.compactMap { byID[$0.id] }
        }
        let coveredIDs = Set(evaluation.coveredExampleIDs.values.flatMap { $0 })
        let coveredAudio = Set(
            hydrated.filter { coveredIDs.contains($0.id) }.compactMap(VoiceExactReviewDecisions.Key.init))
        let namedAudio = Set(ranked.values.flatMap { $0 }.compactMap(VoiceExactReviewDecisions.Key.init))
        let namedIDs = Set(ranked.values.flatMap { $0 }.map(\.id))
        let unnamedGroups =
            (preparedGroups ?? groups(hydrated: hydrated, metadata: metadata, playableIDs: playableIDs, policy: policy))
            .compactMap {
                source -> VoiceIdentificationGroup? in
                func unnamed(_ example: VoiceExample) -> Bool {
                    availableIDs.contains(example.id) && !coveredIDs.contains(example.id)
                        && VoiceExactReviewDecisions.Key(example).map { !coveredAudio.contains($0) } == true
                        && example.personID == nil && example.namedPersonID == nil
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
        return Self(
            revision: revision, candidates: ranked, unnamedGroups: unnamedGroups,
            coveredExampleIDs: evaluation.coveredExampleIDs.mapValues { $0.intersection(playableIDs) })
    }

    /// Pending reference-selection records are background work. Keep every
    /// independent turn available until typed vectors can establish consistency.
    static func selectiveEvidence(_ examples: [VoiceExample]) -> [VoiceExample] {
        // Metadata has no vectors, so it cannot establish voice consistency.
        // Typed, hydrated evidence supplies the acoustic sampling stage later.
        examples.filter { $0.selectedReference == nil || $0.review == .confirmed }
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
        // Only authored grouping grants hidden evidence membership. Automatic
        // turn representatives are questions, so omitted turns keep independent
        // attribution and never inherit a name through an old provider group ID.
        for example in metadata where !included.contains(example.id) && example.manuallyGrouped {
            let effective = decisions.applying(to: example)
            guard !effective.manuallyCleared, !effective.excluded else { continue }
            if let index = groups.firstIndex(where: { group in
                group.evidenceExamples.contains { $0.manuallyGrouped && $0.groupID == example.groupID }
            }) {
                groups[index].duplicateExamples.append(example)
            }
        }
        return groups.filter { !$0.examples.isEmpty }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
