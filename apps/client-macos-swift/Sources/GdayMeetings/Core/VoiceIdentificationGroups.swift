import Foundation

struct VoiceIdentificationGroup: Identifiable, Sendable {
    var id: UUID
    var examples: [VoiceExample]
    var representativeID: UUID
    var duplicateExamples: [VoiceExample] = []

    /// Naming applies to all stored evidence; playback shows each excerpt once.
    var evidenceExamples: [VoiceExample] { examples + duplicateExamples }
}

/// Exact audio decisions survive regenerated provider IDs. The key includes the
/// audio revision and every supported span; adjacent or similar audio is independent.
struct VoiceExactReviewDecisions {
    struct Span: Hashable {
        var start: Double
        var end: Double
    }
    struct Key: Hashable {
        var meetingID: UUID
        var source: String
        var revision: String
        var file: String
        var spans: [Span]
        init?(_ example: VoiceExample) {
            guard let revision = example.audioRevision, let range = example.range else { return nil }
            meetingID = example.meetingID
            source = example.source
            self.revision = revision
            file = range.audioFile
            spans = range.supportSpans.map { Span(start: $0.start, end: $0.end) }
        }
    }
    private struct Decision {
        var excluded = false
        var excludedIdentities: Set<UUID> = []
        var cleared = false
        var rejected: Set<UUID> = []
        var confirmed: Set<UUID> = []
    }
    private var decisions: [Key: Decision] = [:]
    init(_ examples: [VoiceExample]) {
        for example in examples {
            guard let key = Key(example) else { continue }
            var value = decisions[key] ?? Decision()
            value.excluded = value.excluded || example.excluded
            if example.excluded, let identity = example.personID ?? example.namedPersonID {
                value.excludedIdentities.insert(identity)
            }
            value.cleared = value.cleared || example.manuallyCleared
            value.rejected.formUnion(example.rejectedPersonIDs)
            if example.review == .confirmed { value.confirmed.insert(example.personID ?? example.id) }
            decisions[key] = value
        }
    }
    func applying(to example: VoiceExample) -> VoiceExample {
        guard let key = Key(example), let decision = decisions[key] else { return example }
        var value = example
        let identity = example.personID ?? example.namedPersonID
        let contradictsConfirmation =
            identity.map { !decision.confirmed.isEmpty && !decision.confirmed.contains($0) } == true
            || !Set(example.rejectedPersonIDs).isDisjoint(with: decision.confirmed)
        let inheritsExclusion =
            example.review != .confirmed
            && (identity == nil || identity.map { decision.excludedIdentities.contains($0) } == true)
        value.excluded = value.excluded || (decision.excluded && inheritsExclusion)
        // Compatible records are cleared together by the canonical command.
        // A different explicit confirmation remains independent evidence.
        value.manuallyCleared = value.manuallyCleared || (decision.cleared && example.review != .confirmed)
        value.rejectedPersonIDs = Array(Set(value.rejectedPersonIDs).union(decision.rejected))
        if example.review != .confirmed && !decision.confirmed.isEmpty && !contradictsConfirmation {
            value.manuallyCleared = true
        }
        return value
    }
}

enum VoiceIdentificationSelection {
    /// Existing groups retain their identity. Additional proposed joins compare
    /// unnamed samples with fixed anchors in the same recording and audio source.
    /// At most 64 anchors per recording/source are searched; overflow stays separate.
    static func groups(_ examples: [VoiceExample], includeExcluded: Bool = false) -> [VoiceIdentificationGroup] {
        let decisions = VoiceExactReviewDecisions(examples)
        let eligible = examples.filter { original in
            let value = decisions.applying(to: original)
            return (includeExcluded || !value.excluded) && !value.manuallyCleared
                && value.range.map { $0.speechDuration >= 1 } == true && value.audioRevision != nil
                && value.sourceResolutionIssue == nil
                && (value.embeddings.isEmpty || value.embeddings.contains(where: \.isValid))
        }
        let existing = Dictionary(grouping: eligible, by: \.groupID).values.sorted {
            $0[0].groupID.uuidString < $1[0].groupID.uuidString
        }
        struct Recording: Hashable {
            var meetingID: UUID
            var file: String
            var source: String
        }
        var result: [VoiceIdentificationGroup] = []
        var anchors: [Recording: [Int]] = [:]
        for members in existing {
            let ordered = members.sorted {
                ($0.start ?? 0) == ($1.start ?? 0)
                    ? $0.id.uuidString < $1.id.uuidString : ($0.start ?? 0) < ($1.start ?? 0)
            }
            let representative = ordered.max { ($0.range?.speechDuration ?? 0) < ($1.range?.speechDuration ?? 0) }!
            let key = Recording(
                meetingID: representative.meetingID, file: representative.audioFile!, source: representative.source)
            let canJoin = ordered.allSatisfy {
                !$0.manuallyGrouped && $0.personID == nil && $0.suggestedPersonID == nil && $0.namedPersonID == nil
                    && $0.rejectedPersonIDs.isEmpty && !$0.excluded && $0.meetingID == key.meetingID
                    && $0.audioFile == key.file && $0.source == key.source
            }
            let match =
                canJoin
                ? anchors[key, default: []].first { index in
                    guard let anchor = result[index].examples.first(where: { $0.id == result[index].representativeID })
                    else { return false }
                    return ordered.allSatisfy { (VoiceReviewSelection.similarity($0, anchor) ?? -1) >= 0.95 }
                } : nil
            if let match {
                result[match].examples.append(contentsOf: ordered)
            }
            else {
                let index = result.count
                result.append(.init(id: representative.groupID, examples: ordered, representativeID: representative.id))
                if canJoin && anchors[key, default: []].count < 64 { anchors[key, default: []].append(index) }
            }
        }
        return distinctExcerpts(result)
    }

    /// Collapse only equivalent human decisions. Provider IDs and automatic
    /// suggestions do not make a second playback of the same audio useful.
    static func sameDecision(_ left: VoiceExample, _ right: VoiceExample) -> Bool {
        left.personID == right.personID && left.namedPersonID == right.namedPersonID
            && (left.review == .confirmed) == (right.review == .confirmed)
            && Set(left.rejectedPersonIDs) == Set(right.rejectedPersonIDs)
            && left.excluded == right.excluded && left.manuallyCleared == right.manuallyCleared
            && left.manuallyGrouped == right.manuallyGrouped
            && (!left.manuallyGrouped || left.groupID == right.groupID)
    }

    static func distinctExcerpts(_ groups: [VoiceIdentificationGroup]) -> [VoiceIdentificationGroup] {
        let decisions = VoiceExactReviewDecisions(groups.flatMap(\.evidenceExamples))
        var result: [VoiceIdentificationGroup] = []
        var locations: [VoiceExactReviewDecisions.Key: [(group: Int, example: VoiceExample)]] = [:]
        for group in groups {
            let index = result.count
            var visible = group
            visible.examples = []
            visible.duplicateExamples = []
            result.append(visible)
            for example in group.evidenceExamples {
                let key = VoiceExactReviewDecisions.Key(example)
                if let key,
                    let match = locations[key]?.first(where: {
                        sameDecision(decisions.applying(to: $0.example), decisions.applying(to: example))
                    })
                {
                    result[match.group].duplicateExamples.append(example)
                }
                else {
                    result[index].examples.append(example)
                    if let key { locations[key, default: []].append((index, example)) }
                }
            }
            if !result[index].examples.contains(where: { $0.id == result[index].representativeID }),
                let first = result[index].examples.first
            {
                result[index].representativeID = first.id
            }
        }
        return result.filter { !$0.examples.isEmpty }
    }
}
