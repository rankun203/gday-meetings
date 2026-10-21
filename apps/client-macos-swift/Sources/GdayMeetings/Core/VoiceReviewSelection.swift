import Foundation

/// Human review uses a wider similarity range than automatic association. These
/// scores order questions; they never confirm an identity or enter its profile.
enum VoiceReviewSelection {
    // Initial review heuristic, pending evaluation with reviewed recordings.
    static let minimumSimilarity = 0.55

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

    static func rank(_ examples: [VoiceExample], for personID: UUID, limit: Int = 48) -> [VoiceExample] {
        rank(examples, for: [personID], limit: limit)[personID] ?? []
    }

    /// Hydration, representative selection and candidate-to-person distances are
    /// shared by the chooser and individual queues; counts describe these arrays.
    static func rank(_ examples: [VoiceExample], for personIDs: Set<UUID>, limit: Int = 48) -> [UUID: [VoiceExample]] {
        guard !personIDs.isEmpty else { return [:] }
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
        var scored: [UUID: [(example: VoiceExample, score: Double)]] = [:]
        for original in examples {
            let example = exactDecisions.applying(to: original)
            guard isEligible(example) else { continue }
            let strengths = representatives.compactMapValues { values in
                values.compactMap { similarity(example, $0) }.max()
            }
            let best = strengths.sorted { $0.value > $1.value }.prefix(2)
            var plausible = Set(strengths.filter { $0.value >= minimumSimilarity }.keys).intersection(personIDs)
            if let suggested = example.namedPersonID ?? example.suggestedPersonID, personIDs.contains(suggested) {
                plausible.insert(suggested)
            }
            for personID in plausible where !example.rejectedPersonIDs.contains(personID) {
                let strength = strengths[personID] ?? minimumSimilarity
                let competitor = best.first { $0.key != personID }?.value ?? -1
                let boundary = max(0, 1 - abs(strength - SpeakerRecognition.threshold) / 0.30)
                let ambiguity = max(0, 1 - abs(strength - competitor) / 0.15)
                scored[personID, default: []].append((original, 0.55 * boundary + 0.30 * ambiguity + 0.15 * strength))
            }
        }
        return Dictionary(uniqueKeysWithValues: personIDs.map { ($0, select(scored[$0] ?? [], for: $0, limit: limit)) })
    }

    private static func select(
        _ candidates: [(example: VoiceExample, score: Double)], for personID: UUID, limit: Int
    ) -> [VoiceExample] {
        let decisions = VoiceExactReviewDecisions(candidates.map(\.example))
        // Naming promises individual review of every associated excerpt. Keep
        // those exact-distinct questions ahead of sampled automatic suggestions.
        let associated: [VoiceExample] = candidates.compactMap {
            $0.example.namedPersonID == personID ? $0.example : nil
        }
        let explicit = associated.sorted { left, right in
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }
        var selected: [VoiceExample] = []
        var selectedKeys = Set<VoiceExactReviewDecisions.Key>()
        for example in explicit {
            if let key = VoiceExactReviewDecisions.Key(example), !selectedKeys.insert(key).inserted { continue }
            selected.append(example)
        }
        var scored = candidates.filter { candidate in
            guard candidate.example.namedPersonID != personID else { return false }
            return VoiceExactReviewDecisions.Key(candidate.example).map { !selectedKeys.contains($0) } ?? true
        }
        var meetings = Set(selected.map(\.meetingID))
        let automaticLimit = selected.count + max(0, limit)
        while !scored.isEmpty && selected.count < automaticLimit {
            scored.sort { left, right in
                let lhs = left.score + (meetings.contains(left.example.meetingID) ? 0 : 0.20)
                let rhs = right.score + (meetings.contains(right.example.meetingID) ? 0 : 0.20)
                return lhs == rhs ? left.example.id.uuidString < right.example.id.uuidString : lhs > rhs
            }
            let next = scored.removeFirst().example
            selected.append(next)
            meetings.insert(next.meetingID)
            scored.removeAll { redundant(decisions.applying(to: $0.example), with: decisions.applying(to: next)) }
        }
        return selected
    }

    private static func redundant(_ left: VoiceExample, with right: VoiceExample) -> Bool {
        guard left.meetingID == right.meetingID, left.audioRevision == right.audioRevision,
            left.source == right.source, VoiceIdentificationSelection.sameDecision(left, right),
            let a = left.range, let b = right.range, a.audioFile == b.audioFile
        else { return false }
        let overlap = a.supportSpans.reduce(0.0) { total, span in
            total + b.supportSpans.reduce(0.0) { $0 + max(0, min(span.end, $1.end) - max(span.start, $1.start)) }
        }
        if overlap / min(a.speechDuration, b.speechDuration) >= 0.8 { return true }
        return left.groupID == right.groupID && (similarity(left, right) ?? -1) >= 0.985
    }
}
