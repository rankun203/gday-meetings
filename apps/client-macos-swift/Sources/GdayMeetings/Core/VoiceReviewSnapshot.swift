import Foundation

/// One library state supplies every review count and playback queue. Hidden
/// evidence stays attached to a group so naming covers its original records.
struct VoiceReviewSnapshot: Sendable {
    var revision: Int
    var candidates: [UUID: [VoiceExample]]
    var unnamedGroups: [VoiceIdentificationGroup]

    static func make(
        hydrated: [VoiceExample], metadata: [VoiceExample], playableIDs: Set<UUID>,
        personIDs: Set<UUID>, revision: Int
    ) -> Self {
        let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        // Unavailable confirmed records remain reference evidence, but cannot
        // become review questions even if their metadata still has a range.
        let ranked = VoiceReviewSelection.rank(hydrated, for: personIDs).mapValues { values in
            values.filter { playableIDs.contains($0.id) }.compactMap { byID[$0.id] }
        }
        let namedAudio = Set(ranked.values.flatMap { $0 }.compactMap(VoiceExactReviewDecisions.Key.init))
        let namedIDs = Set(ranked.values.flatMap { $0 }.map(\.id))
        let unnamedGroups = groups(hydrated: hydrated, metadata: metadata, playableIDs: playableIDs).compactMap {
            source -> VoiceIdentificationGroup? in
            func unnamed(_ example: VoiceExample) -> Bool {
                example.personID == nil && example.namedPersonID == nil && example.suggestedPersonID == nil
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

    static func groups(
        hydrated: [VoiceExample], metadata: [VoiceExample], playableIDs: Set<UUID>
    ) -> [VoiceIdentificationGroup] {
        let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        var groups = VoiceIdentificationSelection.groups(hydrated).map { source in
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
