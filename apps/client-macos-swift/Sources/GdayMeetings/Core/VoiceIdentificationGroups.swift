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
    /// Human groups retain identity. Automatic proposals are recomputed from
    /// captured vectors so changing policy can split or join old proposals.
    static func groups(
        _ examples: [VoiceExample], includeExcluded: Bool = false, policy: VoiceMatchingPolicy = .default
    ) -> [VoiceIdentificationGroup] {
        let examples = VoiceTurnReviewSelection.select(examples)
        let decisions = VoiceExactReviewDecisions(examples)
        let eligible = examples.filter { original in
            let value = decisions.applying(to: original)
            return (includeExcluded || !value.excluded) && !value.manuallyCleared
                && value.range.map { $0.speechDuration >= 1 } == true && value.audioRevision != nil
                && value.sourceResolutionIssue == nil
                && (value.embeddings.isEmpty || value.embeddings.contains(where: \.isValid))
        }
        // Legacy records did not distinguish authored linkage from automatic
        // proposals. Preserve linked evidence, including hidden recovery members,
        // rather than reinterpret a historical group from today's vectors.
        let legacyLinkedGroups = Set(
            Dictionary(grouping: examples, by: \.groupID).compactMap { id, members in
                members.count > 1 && members.contains { $0.origin == nil } ? id : nil
            })
        func automatic(_ value: VoiceExample) -> Bool {
            !legacyLinkedGroups.contains(value.groupID) && !value.manuallyGrouped && value.personID == nil
                && value.suggestedPersonID == nil
                && value.namedPersonID == nil && !value.excluded
                && value.review != .confirmed
        }
        let protectedGroups = Dictionary(grouping: eligible.filter { !automatic($0) }, by: \.groupID).values
        let proposals = VoiceAutomaticGrouping.groups(eligible.filter(automatic), policy: policy)
        var result: [VoiceIdentificationGroup] = []
        for members in Array(protectedGroups) + proposals {
            let ordered = members.sorted {
                ($0.start ?? 0) == ($1.start ?? 0)
                    ? $0.id.uuidString < $1.id.uuidString : ($0.start ?? 0) < ($1.start ?? 0)
            }
            guard
                let representative = ordered.max(by: {
                    let lhs = VoiceSampleQuality.priority(example: $0)
                    let rhs = VoiceSampleQuality.priority(example: $1)
                    if lhs != rhs { return lhs < rhs }
                    let left = $0.range?.speechDuration ?? 0
                    let right = $1.range?.speechDuration ?? 0
                    return left == right ? $0.id.uuidString > $1.id.uuidString : left < right
                })
            else { continue }
            let id =
                automatic(representative)
                ? members.map(\.id).min(by: { $0.uuidString < $1.uuidString })! : representative.groupID
            result.append(.init(id: id, examples: ordered, representativeID: representative.id))
        }
        let distinct = distinctExcerpts(result.sorted { $0.id.uuidString < $1.id.uuidString })
        let priorities = Dictionary(
            uniqueKeysWithValues: distinct.map { group in
                (
                    group.id,
                    group.examples.first { $0.id == group.representativeID }
                        .map { VoiceSampleQuality.priority(example: $0) } ?? 1
                )
            })
        let coverage = Dictionary(
            uniqueKeysWithValues: distinct.map { ($0.id, Set($0.examples.map(\.meetingID)).count) })
        return distinct.sorted { left, right in
            let lhs =
                priorities[left.id] ?? 1
            let rhs =
                priorities[right.id] ?? 1
            if lhs != rhs { return lhs > rhs }
            let leftMeetings = coverage[left.id] ?? 0
            let rightMeetings = coverage[right.id] ?? 0
            if leftMeetings != rightMeetings { return leftMeetings > rightMeetings }
            return left.id.uuidString < right.id.uuidString
        }
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
