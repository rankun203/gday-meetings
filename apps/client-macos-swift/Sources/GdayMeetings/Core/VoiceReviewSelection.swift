import Foundation

/// Human review uses a wider similarity range than automatic association. These
/// scores order questions; they never confirm an identity or enter its profile.
enum VoiceReviewSelection {
    // Initial review heuristic, pending evaluation with reviewed recordings.
    static let minimumSimilarity = VoiceMatchingPolicy.default.suggestionThreshold
    private static let nearDuplicateSimilarity = 0.985
    private typealias Candidate = (example: VoiceExample, effective: VoiceExample, score: Double)

    static func sameAudio(_ left: VoiceExample, _ right: VoiceExample) -> Bool {
        guard let key = VoiceExactReviewDecisions.Key(left) else { return false }
        return key == VoiceExactReviewDecisions.Key(right)
    }

    /// One physical excerpt contributes once per embedding model and person.
    /// Provider records and their other model representations remain preserved.
    static func distinctRepresentations(_ examples: [VoiceExample]) -> [VoiceExample] {
        enum Audio: Hashable {
            case exact(VoiceExactReviewDecisions.Key)
            case unresolved(UUID)
        }
        struct Key: Hashable {
            let audio: Audio
            let personID: UUID?
            let model: EmbeddingType
        }
        var seen = Set<Key>()
        var result: [VoiceExample] = []
        for example in examples.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let audio = VoiceExactReviewDecisions.Key(example).map(Audio.exact) ?? .unresolved(example.id)
            for embedding in example.embeddings where embedding.isValid {
                guard seen.insert(Key(audio: audio, personID: example.personID, model: embedding.type)).inserted else {
                    continue
                }
                var value = example
                value.embeddings = [embedding]
                result.append(value)
            }
        }
        return result
    }

    static func similarity(_ left: VoiceExample, _ right: VoiceExample) -> Double? {
        left.embeddings.filter(\.isValid).flatMap { first in
            right.embeddings.filter { $0.isValid && $0.type == first.type }.compactMap {
                SpeakerRecognition.similarity(first.values, $0.values)
            }
        }.max()
    }

    static func isEligible(_ example: VoiceExample) -> Bool {
        example.acceptsSuggestions && example.range.map { $0.speechDuration >= 1 } == true
            && example.audioRevision != nil && example.sourceResolutionIssue == nil
            && (example.embeddings.isEmpty || example.embeddings.contains(where: \.isValid))
    }

    static func rank(
        _ examples: [VoiceExample], for personID: UUID, limit: Int = 48, policy: VoiceMatchingPolicy = .default
    ) -> [VoiceExample] {
        rank(examples, for: [personID], limit: limit, policy: policy)[personID] ?? []
    }

    struct Evaluation {
        var candidates: [UUID: [VoiceExample]]
        var coveredExampleIDs: [UUID: Set<UUID>]
    }

    static func rank(
        _ examples: [VoiceExample], for personIDs: Set<UUID>, limit: Int = 48, policy: VoiceMatchingPolicy = .default
    ) -> [UUID: [VoiceExample]] {
        evaluate(examples, for: personIDs, limit: limit, policy: policy).candidates
    }

    /// Selection and coverage share one scoring pass. A session may retire an
    /// admitted question only when confirmed evidence already covers it.
    static func evaluate(
        _ examples: [VoiceExample], for personIDs: Set<UUID>, limit: Int = 48, policy: VoiceMatchingPolicy = .default
    ) -> Evaluation {
        let policy = policy.normalized
        guard !personIDs.isEmpty else { return Evaluation(candidates: [:], coveredExampleIDs: [:]) }
        let conflicts = VoiceReviewConflicts.confirmedExampleIDs(in: examples)
        let confirmed = examples.filter {
            $0.review == .confirmed && $0.personID != nil && !$0.excluded && !conflicts.contains($0.id)
        }
        let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id.uuidString, $0) })
        let representatives = Dictionary(grouping: confirmed, by: { $0.personID! }).mapValues { values in
            let evidence = distinctRepresentations(values).flatMap { example in
                example.embeddings.filter(\.isValid).map {
                    SpeakerEvidenceSample(
                        id: example.id.uuidString, source: example.source,
                        localSpeakerID: example.groupID.uuidString, start: example.start ?? 0,
                        end: example.end ?? 0, embedding: $0, spans: example.spans)
                }
            }
            return Dictionary(grouping: evidence, by: \.model).values.flatMap {
                VoiceProfileSelection.select($0).compactMap { sample in
                    byID[sample.id].map { example in
                        var value = example
                        value.embeddings = [sample.embedding]
                        return value
                    }
                }
            }
        }
        let exactDecisions = VoiceExactReviewDecisions(examples)
        var scored: [UUID: [Candidate]] = [:]
        var coveredExampleIDs: [UUID: Set<UUID>] = [:]
        // Decide usefulness before sampling: a clear turn in a detected cluster
        // must not hide a weaker, independently attributed turn worth reviewing.
        for original in examples {
            let example = exactDecisions.applying(to: original)
            guard isEligible(example), example.currentSampleQuality?.issue == nil,
                example.embeddings.contains(where: \.isValid)
            else { continue }
            let strengths = representatives.compactMapValues { values in
                values.compactMap { similarity(example, $0) }.max()
            }
            let eligibleStrengths = strengths.filter { !example.rejectedPersonIDs.contains($0.key) }
            let best = eligibleStrengths.sorted { $0.value > $1.value }.prefix(2)
            var plausible = Set(eligibleStrengths.filter { $0.value >= policy.suggestionThreshold }.keys).intersection(
                personIDs)
            if let suggested = example.namedPersonID ?? example.suggestedPersonID, personIDs.contains(suggested) {
                plausible.insert(suggested)
            }
            for personID in plausible where !example.rejectedPersonIDs.contains(personID) {
                let strength = strengths[personID] ?? policy.suggestionThreshold
                let competitor = best.first { $0.key != personID }?.value ?? -1
                // A question should improve the voice profile or resolve a real
                // ambiguity. Clear associations already organize the recording.
                if strength >= policy.automaticThreshold && strength - competitor >= policy.minimumMargin {
                    coveredExampleIDs[personID, default: []].insert(original.id)
                    continue
                }
                let covered = (representatives[personID] ?? []).contains {
                    $0.source == example.source && (similarity(example, $0) ?? -1) >= nearDuplicateSimilarity
                }
                if covered {
                    coveredExampleIDs[personID, default: []].insert(original.id)
                    continue
                }
                let boundary = max(0, 1 - abs(strength - policy.automaticThreshold) / 0.30)
                let ambiguity = max(0, 1 - abs(strength - competitor) / 0.15)
                scored[personID, default: []].append(
                    (original, example, 0.55 * boundary + 0.30 * ambiguity + 0.15 * strength))
            }
        }
        return Evaluation(
            candidates: Dictionary(
                uniqueKeysWithValues: personIDs.map { ($0, select(scored[$0] ?? [], limit: limit, policy: policy)) }),
            coveredExampleIDs: coveredExampleIDs)
    }

    private static func select(
        _ candidates: [Candidate], limit: Int, policy: VoiceMatchingPolicy
    ) -> [VoiceExample] {
        guard limit > 0 else { return [] }
        struct Condition: Hashable {
            var source: String
            var namedPersonID: UUID?
            var rejectedPersonIDs: Set<UUID>
            var models: Set<EmbeddingType>
        }
        let byID = Dictionary(candidates.map { ($0.example.id, $0) }, uniquingKeysWith: { first, _ in first })
        let conditions = Dictionary(grouping: candidates.map(\.effective)) { example in
            return Condition(
                source: example.source, namedPersonID: example.namedPersonID,
                rejectedPersonIDs: Set(example.rejectedPersonIDs),
                models: Set(example.embeddings.filter(\.isValid).map(\.type)))
        }
        // Complete-link groups require every pair to agree, so a chain of
        // similar turns cannot hide a conflicting voice. This only chooses
        // questions; confirmation never expands to undisplayed members.
        var representatives: [Candidate] = []
        for values in conditions.values {
            for group in VoiceAutomaticGrouping.groups(values, policy: policy) {
                let best = group.compactMap { byID[$0.id] }.sorted(by: preferred).first
                if let best { representatives.append(best) }
            }
        }
        return representatives.sorted(by: preferred).prefix(limit).map(\.example)
    }

    private static func preferred(
        _ left: Candidate, _ right: Candidate
    ) -> Bool {
        let leftQuality = VoiceSampleQuality.priority(example: left.example)
        let rightQuality = VoiceSampleQuality.priority(example: right.example)
        if leftQuality != rightQuality { return leftQuality > rightQuality }
        if left.score != right.score { return left.score > right.score }
        let leftDuration = left.example.range?.speechDuration ?? 0
        let rightDuration = right.example.range?.speechDuration ?? 0
        if leftDuration != rightDuration { return leftDuration > rightDuration }
        return left.example.id.uuidString < right.example.id.uuidString
    }
}
