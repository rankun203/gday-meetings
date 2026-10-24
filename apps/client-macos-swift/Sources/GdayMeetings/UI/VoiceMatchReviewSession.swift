import Foundation

/// Presentation state retains the queue and the candidate while a reference is playing.
struct VoiceMatchReviewSession {
    enum Decision: Equatable {
        case confirmed(UUID)
        case rejected
        case ignored
        case skipped
    }
    struct NamingSnapshot {
        let personID: UUID?
        let examples: [VoiceExample]
        let decisions: [UUID: Decision]
        let alternateExampleIDs: Set<UUID>
        let replacedExamples: [VoiceExample]
        let additionalCandidates: [VoiceExample]
        let noLongerNeededIDs: Set<UUID>
    }
    struct Step {
        let exampleID: UUID
        let undoID: UUID?
        var namingSnapshot: NamingSnapshot? = nil
        var referenceID: UUID? = nil
        var candidateID: UUID? = nil
        var previousDecision: Decision? = nil
    }

    private(set) var personID: UUID?
    private(set) var examples: [VoiceExample]
    private(set) var candidateID: UUID?
    private(set) var referenceID: UUID?
    private(set) var decisions: [UUID: Decision] = [:]
    private(set) var history: [Step] = []
    private(set) var unavailableIDs: Set<UUID> = []
    private(set) var alternateExampleIDs: Set<UUID> = []
    private(set) var additionalCandidates: [VoiceExample] = []
    private(set) var noLongerNeededIDs: Set<UUID> = []
    private var hasInitialBatch = false
    private var replacedExamples: [VoiceExample] = []

    mutating func showAlternative(_ example: VoiceExample, currentEvidence: [VoiceExample]) {
        guard let candidateID, decisions[candidateID] == nil,
            let index = examples.firstIndex(where: { $0.id == candidateID })
        else { return }
        replacedExamples.append(examples[index])
        alternateExampleIDs.insert(example.id)
        examples[index] = example
        for step in history.indices where history[step].candidateID == candidateID {
            history[step].candidateID = example.id
        }
        unavailableIDs.remove(candidateID)
        noLongerNeededIDs.remove(candidateID)
        refreshExamples(currentEvidence, authoritative: true)
        additionalCandidates.removeAll { Self.sameOpportunity($0, as: example) }
        selectCandidate(example.id)
    }

    struct RefreshInput {
        var examples: [VoiceExample]
        var groupEvidence: [VoiceExample]
    }

    func refreshInput(
        from snapshot: VoiceReviewSnapshot, initialGroup: VoiceIdentificationGroup?,
        fallbackPersonID: UUID?, retainedGroupEvidence: [VoiceExample], currentEvidence: [VoiceExample]
    ) -> RefreshInput {
        let current = Dictionary(currentEvidence.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        // Other surfaces can change or remove retained samples. Naming must use
        // their current evidence, while the visible queue preserves unavailable rows.
        let retained = namingEvidence(retainedGroupEvidence.compactMap { current[$0.id] })
        if let person = personID ?? fallbackPersonID {
            return RefreshInput(examples: snapshot.candidates[person] ?? [], groupEvidence: retained)
        }
        guard let initialGroup else { return RefreshInput(examples: [], groupEvidence: retained) }
        let ids = Set(initialGroup.examples.map(\.id))
        let group = snapshot.unnamedGroups.first {
            $0.id == initialGroup.id || $0.examples.contains { ids.contains($0.id) }
        }
        // Preserve naming evidence across completion/refresh so Undo can reopen naming.
        var evidence = group.map { namingEvidence($0.evidenceExamples.compactMap { current[$0.id] }) } ?? retained
        var evidenceIDs = Set(evidence.map(\.id))
        // Prepared alternatives are separate persisted samples. Keep them in
        // this session's naming evidence even if clustering puts them elsewhere.
        evidence += retained.filter {
            alternateExampleIDs.contains($0.id) && evidenceIDs.insert($0.id).inserted
        }
        return RefreshInput(examples: group?.examples ?? [], groupEvidence: evidence)
    }

    /// Replacing an unsuitable excerpt withdraws it from this naming action.
    /// Its saved record remains available for an explicit later correction.
    func namingEvidence(_ values: [VoiceExample]) -> [VoiceExample] {
        values.filter { value in
            !replacedExamples.contains { Self.sameOpportunity($0, as: value) }
                && !additionalCandidates.contains { Self.sameOpportunity($0, as: value) }
        }
    }

    /// Undo restores the original admitted scope synchronously, before a later
    /// snapshot can update the chooser. Dropped alternatives cannot rejoin it.
    func restoredNamingEvidence(initialEvidence: [VoiceExample], currentEvidence: [VoiceExample]) -> [VoiceExample] {
        let current = Dictionary(currentEvidence.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<UUID>()
        return namingEvidence((initialEvidence + examples).compactMap { current[$0.id] }).filter {
            seen.insert($0.id).inserted
        }
    }

    struct Actions {
        let canSkip: Bool
        let canConfirm: Bool
        let canReject: Bool
        let canIgnore: Bool
    }

    static func actions(
        for example: VoiceExample, decision: Decision?, isReference: Bool, personID: UUID?
    ) -> Actions {
        let confirmedPerson: UUID?
        if case .confirmed(let person) = decision {
            confirmedPerson = person
        }
        else if decision == .ignored || decision == .rejected {
            confirmedPerson = nil
        }
        else if example.review == .confirmed {
            confirmedPerson = example.personID
        }
        else {
            confirmedPerson = nil
        }
        return Actions(
            canSkip: !isReference && decision == nil && confirmedPerson == nil,
            canConfirm: confirmedPerson == nil,
            canReject: decision != .rejected && personID != nil
                && (confirmedPerson == nil || confirmedPerson == personID),
            canIgnore: decision != .ignored && !example.excluded)
    }

    init(examples: [VoiceExample] = [], personID: UUID? = nil) {
        self.examples = examples
        self.personID = personID
        hasInitialBatch = !examples.isEmpty
        candidateID = examples.first?.id
    }

    static func distinctExamples(_ examples: [VoiceExample]) -> [VoiceExample] {
        guard let first = examples.first else { return [] }
        return VoiceIdentificationSelection.distinctExcerpts([
            VoiceIdentificationGroup(id: first.groupID, examples: examples, representativeID: first.id)
        ]).flatMap(\.examples)
    }

    /// Apply exact human decisions before presenting references. Keep original
    /// evidence values for stale-write checks and preserve conflicting identities.
    static func referenceExamples(_ examples: [VoiceExample], personID: UUID) -> [VoiceExample] {
        let decisions = VoiceExactReviewDecisions(examples)
        // A vetoed alias must not occupy this person's review slot.
        let candidates = examples.filter { original in
            let effective = decisions.applying(to: original)
            return !effective.excluded && !effective.manuallyCleared
                && !effective.rejectedPersonIDs.contains(personID)
                && original.review == .confirmed && original.personID == personID
        }
        let eligible = VoiceTurnReviewSelection.select(candidates).sorted { left, right in
            if (left.review == .confirmed) != (right.review == .confirmed) { return left.review == .confirmed }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }
        var keys = Set<VoiceExactReviewDecisions.Key>()
        return eligible.filter { example in
            guard let key = VoiceExactReviewDecisions.Key(example) else { return true }
            return keys.insert(key).inserted
        }
    }

    /// A refresh updates the admitted batch. New opportunities wait for an
    /// explicit request, so confirming an excerpt has a predictable finish.
    mutating func refreshQueue(
        _ updated: [VoiceExample], currentEvidence: [VoiceExample]? = nil, admitNewCandidates: Bool = false,
        coveredExampleIDs: Set<UUID> = []
    ) {
        if let currentEvidence {
            refreshExamples(currentEvidence, authoritative: true)
        }
        else {
            refreshExamples(updated)
        }
        noLongerNeededIDs = Set(
            examples.filter {
                decisions[$0.id] == nil && !alternateExampleIDs.contains($0.id) && coveredExampleIDs.contains($0.id)
            }.map(\.id))
        let retained = examples + replacedExamples
        var available: [VoiceExample] = []
        for example in updated {
            guard !retained.contains(where: { Self.sameOpportunity($0, as: example) }),
                !available.contains(where: { Self.sameOpportunity($0, as: example) })
            else { continue }
            available.append(example)
        }
        let admit = !hasInitialBatch || admitNewCandidates
        hasInitialBatch = true
        if admit {
            examples.append(contentsOf: available)
            additionalCandidates = []
            if admitNewCandidates, let next = available.first {
                selectCandidate(next.id)
            }

        }
        else {
            additionalCandidates = available
        }
        if displayedID == nil {
            candidateID =
                examples.first {
                    decisions[$0.id] == nil && !unavailableIDs.contains($0.id) && !noLongerNeededIDs.contains($0.id)
                }?.id
        }
    }

    private static func sameOpportunity(_ left: VoiceExample, as right: VoiceExample) -> Bool {
        left.id == right.id || VoiceReviewSelection.sameAudio(left, right)
    }

    /// References share durable decisions and Undo, while candidate progress
    /// remains the count of the original review queue.
    mutating func recordReference(for id: UUID, undoID: UUID?) {
        history.append(Step(exampleID: id, undoID: undoID, referenceID: id, candidateID: candidateID))
    }

    /// Keep every unnamed record for association while presenting only playable excerpts.
    static func unnamedGroup(
        _ source: VoiceIdentificationGroup, playable: (VoiceExample) -> Bool
    ) -> VoiceIdentificationGroup? {
        func unnamed(_ example: VoiceExample) -> Bool {
            example.personID == nil && example.namedPersonID == nil && example.suggestedPersonID == nil
                && !example.excluded && !example.manuallyCleared
        }
        var group = source
        let unnamedExamples = source.examples.filter(unnamed)
        group.examples = unnamedExamples.filter(playable)
        guard let first = group.examples.first else { return nil }
        group.duplicateExamples =
            source.duplicateExamples.filter(unnamed)
            + unnamedExamples.filter { !playable($0) }
        if !group.examples.contains(where: { $0.id == group.representativeID }) {
            group.representativeID = first.id
        }
        return group
    }

    var remainingCount: Int {
        examples.filter {
            decisions[$0.id] == nil && !unavailableIDs.contains($0.id) && !noLongerNeededIDs.contains($0.id)
        }.count
    }
    var skippedCount: Int { decisions.values.filter { $0 == .skipped }.count }
    var decidedCount: Int { decisions.count - skippedCount }
    var displayedID: UUID? { referenceID ?? candidateID }

    mutating func selectCandidate(_ id: UUID?) {
        candidateID = id
        referenceID = nil
    }

    mutating func selectReference(_ id: UUID) { referenceID = id }
    mutating func returnToCandidate() { referenceID = nil }

    mutating func record(_ decision: Decision, for exampleID: UUID, undoID: UUID?) {
        guard decisions[exampleID] == nil, examples.contains(where: { $0.id == exampleID }) else { return }
        decisions[exampleID] = decision
        noLongerNeededIDs.remove(exampleID)
        history.append(Step(exampleID: exampleID, undoID: undoID))
        advance(after: exampleID)
    }

    /// Correct a completed candidate without counting the same excerpt twice.
    mutating func correct(_ decision: Decision, for exampleID: UUID, undoID: UUID?) {
        guard let previous = decisions[exampleID], examples.contains(where: { $0.id == exampleID }) else { return }
        history.append(Step(exampleID: exampleID, undoID: undoID, previousDecision: previous))
        decisions[exampleID] = decision
        advance(after: exampleID)
    }

    /// Naming changes the proposed person's identity once; each other sample remains undecided.
    mutating func recordNaming(
        personID: UUID, confirmedExampleID: UUID, updatedExamples: [VoiceExample], undoID: UUID?
    ) {
        guard self.personID == nil,
            examples.contains(where: { $0.id == confirmedExampleID })
        else { return }
        let snapshot = NamingSnapshot(
            personID: self.personID, examples: examples, decisions: decisions,
            alternateExampleIDs: alternateExampleIDs, replacedExamples: replacedExamples,
            additionalCandidates: additionalCandidates, noLongerNeededIDs: noLongerNeededIDs)
        self.personID = personID
        refreshExamples(updatedExamples)
        decisions[confirmedExampleID] = .confirmed(personID)
        history.append(Step(exampleID: confirmedExampleID, undoID: undoID, namingSnapshot: snapshot))
        advance(after: confirmedExampleID)
    }

    /// Refresh evidence after our own write without rebuilding or reordering the session.
    mutating func refreshExamples(_ updated: [VoiceExample], authoritative: Bool = false) {
        let values = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        if authoritative { unavailableIDs = Set(examples.filter { values[$0.id] == nil }.map(\.id)) }
        examples = examples.map { values[$0.id] ?? $0 }
    }

    private mutating func advance(after exampleID: UUID) {
        guard let position = examples.firstIndex(where: { $0.id == exampleID }) else { return }
        referenceID = nil
        candidateID =
            examples.dropFirst(position + 1).first {
                decisions[$0.id] == nil && !unavailableIDs.contains($0.id) && !noLongerNeededIDs.contains($0.id)
            }?.id
            ?? examples.first {
                decisions[$0.id] == nil && !unavailableIDs.contains($0.id) && !noLongerNeededIDs.contains($0.id)
            }?.id
    }

    /// Call only after the corresponding durable undo succeeds, or for a local skip.
    mutating func restoreLast(updatedExample: VoiceExample?) {
        restoreLast(updatedExamples: updatedExample.map { [$0] } ?? [])
    }

    mutating func restoreLast(updatedExamples: [VoiceExample]) {
        guard let last = history.popLast() else { return }
        if let snapshot = last.namingSnapshot {
            personID = snapshot.personID
            examples = snapshot.examples
            decisions = snapshot.decisions
            alternateExampleIDs = snapshot.alternateExampleIDs
            replacedExamples = snapshot.replacedExamples
            additionalCandidates = snapshot.additionalCandidates
            noLongerNeededIDs = snapshot.noLongerNeededIDs
        }
        noLongerNeededIDs.remove(last.exampleID)
        if last.namingSnapshot == nil {
            if let previous = last.previousDecision {
                decisions[last.exampleID] = previous
            }
            else {
                decisions.removeValue(forKey: last.exampleID)
            }
        }
        refreshExamples(updatedExamples)
        candidateID = last.referenceID == nil ? last.exampleID : last.candidateID
        referenceID = last.referenceID
    }
}
