import Foundation
import Testing

@testable import GdayMeetings

struct VoiceMatchReviewSessionTests {
    @Test func refreshAfterNamingUsesPersonQueueAndRetainsEvidenceForUndo() {
        let first = sample()
        let next = sample()
        let person = UUID()
        let group = VoiceIdentificationGroup(id: UUID(), examples: [first], representativeID: first.id)
        var session = VoiceMatchReviewSession(examples: [first])
        session.recordNaming(personID: person, confirmedExampleID: first.id, updatedExamples: [first], undoID: UUID())
        let snapshot = VoiceReviewSnapshot(revision: 1, candidates: [person: [next]], unnamedGroups: [])
        let named = session.refreshInput(
            from: snapshot, initialGroup: group, fallbackPersonID: nil, retainedGroupEvidence: group.evidenceExamples,
            currentEvidence: [first, next])
        #expect(named.examples.map(\.id) == [next.id])
        #expect(named.groupEvidence.map(\.id) == [first.id])
        session.refreshQueue(named.examples, currentEvidence: [first, next])
        session.restoreLast(updatedExamples: [first])
        #expect(session.personID == nil)
        let unnamed = session.refreshInput(
            from: snapshot, initialGroup: group, fallbackPersonID: nil, retainedGroupEvidence: named.groupEvidence,
            currentEvidence: [first, next])
        #expect(unnamed.groupEvidence.map(\.id) == [first.id])
        session.recordNaming(personID: person, confirmedExampleID: first.id, updatedExamples: [first], undoID: UUID())
        #expect(session.personID == person)
    }

    private func sample() -> VoiceExample {
        VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav", start: 1, end: 4)
    }

    @Test func referencePlaybackPreservesCandidateAndDoesNotRecordADecision() {
        let first = sample()
        let second = sample()
        let reference = sample()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.selectCandidate(second.id)
        session.selectReference(reference.id)
        #expect(session.displayedID == reference.id)
        #expect(session.candidateID == second.id)
        #expect(session.remainingCount == 2 && session.history.isEmpty)
        session.returnToCandidate()
        #expect(session.displayedID == second.id && session.decisions.isEmpty)
    }

    @Test func decisionsAdvanceWithoutRemovingRowsAndUndoRestoresIgnoredSample() {
        let first = sample()
        let second = sample()
        let person = UUID()
        let token = UUID()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.confirmed(person), for: first.id, undoID: token)
        #expect(session.examples.map(\.id) == [first.id, second.id])
        #expect(session.candidateID == second.id && session.decidedCount == 1)
        session.record(.ignored, for: second.id, undoID: UUID())
        #expect(session.candidateID == nil && session.remainingCount == 0)
        session.restoreLast(updatedExample: second)
        #expect(session.candidateID == second.id && session.decisions[second.id] == nil)
        #expect(session.history.last?.undoID == token)
    }

    @Test func skipIsLocalAndCompletedRowsCannotOverwriteTheirDecision() {
        let first = sample()
        let second = sample()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.skipped, for: first.id, undoID: nil)
        #expect(session.skippedCount == 1 && session.decidedCount == 0)
        #expect(session.history.last?.undoID == nil)
        session.selectCandidate(first.id)
        session.record(.rejected, for: first.id, undoID: UUID())
        #expect(session.decisions[first.id] == .skipped && session.history.count == 1)
        session.restoreLast(updatedExample: nil)
        #expect(session.remainingCount == 2 && session.candidateID == first.id)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func namingConfirmsOnlyTheAnchorAndKeepsAssociatedSamplesInOrder() {
        let first = sample()
        let second = sample()
        let person = UUID()
        var confirmed = first
        confirmed.personID = person
        confirmed.review = .confirmed
        var associated = second
        associated.namedPersonID = person
        associated.suggestedPersonID = person
        associated.review = .suggested
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.recordNaming(
            personID: person, confirmedExampleID: first.id,
            updatedExamples: [associated, confirmed], undoID: UUID())
        #expect(session.personID == person)
        #expect(session.examples.map(\.id) == [first.id, second.id])
        #expect(session.decisions == [first.id: .confirmed(person)])
        #expect(session.remainingCount == 1 && session.candidateID == second.id)
        #expect(session.examples[1].namedPersonID == person && session.examples[1].review == .suggested)
    }

    @Test func undoNamingRestoresUnnamedGroupAfterUndoingAnIndividualDecision() {
        let first = sample()
        let second = sample()
        let person = UUID()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.recordNaming(
            personID: person, confirmedExampleID: first.id, updatedExamples: [], undoID: UUID())
        session.record(.rejected, for: second.id, undoID: UUID())
        session.restoreLast(updatedExamples: [second])
        #expect(session.personID == person && session.decisions[first.id] == .confirmed(person))
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.personID == nil && session.decisions.isEmpty && session.history.isEmpty)
        #expect(session.examples.map(\.id) == [first.id, second.id] && session.candidateID == first.id)
    }

    @Test func namingAndUndoPreserveEarlierLocalSkip() {
        let first = sample()
        let second = sample()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.skipped, for: first.id, undoID: nil)
        session.recordNaming(
            personID: UUID(), confirmedExampleID: second.id, updatedExamples: [], undoID: UUID())
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.personID == nil && session.decisions == [first.id: .skipped])
        #expect(session.candidateID == second.id && session.history.count == 1)
    }

    @Test func unnamedWorkRequiresPlayableAudioButRetainsUnavailableAssociationMembers() {
        let playable = sample()
        let unavailable = sample()
        var named = sample()
        named.namedPersonID = UUID()
        var alias = playable
        alias.id = UUID()
        let group = VoiceIdentificationGroup(
            id: UUID(), examples: [unavailable, named, playable], representativeID: unavailable.id,
            duplicateExamples: [alias])
        let result = VoiceMatchReviewSession.unnamedGroup(group) { $0.id == playable.id }
        #expect(result?.examples.map(\.id) == [playable.id])
        #expect(result?.representativeID == playable.id)
        #expect(Set(result?.evidenceExamples.map(\.id) ?? []) == Set([playable.id, unavailable.id, alias.id]))
        #expect(VoiceMatchReviewSession.unnamedGroup(group, playable: { _ in false }) == nil)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func newSessionStartsWithFirstDisplayedSampleAndRefreshPreservesNavigation() {
        let first = sample()
        let second = sample()
        let third = sample()
        var session = VoiceMatchReviewSession(examples: [first, second])
        #expect(session.displayedID == first.id)
        session.selectCandidate(second.id)
        session.refreshQueue([third, second, first])
        #expect(session.displayedID == second.id)
        #expect(session.examples.map(\.id) == [first.id, second.id, third.id])
        let reference = sample()
        session.selectReference(reference.id)
        session.refreshQueue([first, second])
        #expect(session.displayedID == reference.id && session.candidateID == second.id)
    }

    @Test func referenceDecisionsKeepCandidateProgressAndUndoRestoresReferenceFocus() {
        let candidate = sample()
        let reference = sample()
        let token = UUID()
        var session = VoiceMatchReviewSession(examples: [candidate])
        session.selectReference(reference.id)
        session.recordReference(for: reference.id, undoID: token)
        #expect(session.remainingCount == 1 && session.decidedCount == 0)
        #expect(session.history.last?.undoID == token)
        session.returnToCandidate()
        session.restoreLast(updatedExamples: [reference])
        #expect(session.displayedID == reference.id && session.candidateID == candidate.id)
        #expect(session.history.isEmpty)
    }

    @Test func referenceProjectionHonorsExactConfirmationWithoutMutatingEvidence() {
        let person = UUID()
        var confirmed = sample()
        confirmed.audioRevision = "synthetic-audio"
        confirmed.personID = person
        confirmed.review = .confirmed
        var associated = confirmed
        associated.id = UUID()
        associated.personID = nil
        associated.namedPersonID = person
        associated.review = .suggested
        let projected = VoiceMatchReviewSession.referenceExamples([associated, confirmed], personID: person)
        #expect(projected.map(\.id) == [confirmed.id])
        #expect(associated.namedPersonID == person && associated.review == .suggested)
        var otherRevision = associated
        otherRevision.id = UUID()
        otherRevision.audioRevision = "other-audio"
        var otherSource = associated
        otherSource.id = UUID()
        otherSource.source = "microphone"
        #expect(
            VoiceMatchReviewSession.referenceExamples(
                [confirmed, associated, otherRevision, otherSource], personID: person
            ).count == 3)
        var rejected = confirmed
        rejected.personID = nil
        rejected.review = .rejected
        rejected.rejectedPersonIDs = [person]
        #expect(VoiceMatchReviewSession.referenceExamples([rejected, associated], personID: person).isEmpty)
    }

    @Test func referenceProjectionRetainsConflictingConfirmedIdentities() {
        let firstPerson = UUID()
        let otherPerson = UUID()
        var first = sample()
        first.audioRevision = "synthetic-audio"
        first.personID = firstPerson
        first.review = .confirmed
        var other = first
        other.id = UUID()
        other.personID = otherPerson
        let evidence = [first, other]
        #expect(VoiceMatchReviewSession.referenceExamples(evidence, personID: firstPerson).map(\.id) == [first.id])
        #expect(VoiceMatchReviewSession.referenceExamples(evidence, personID: otherPerson).map(\.id) == [other.id])
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func correctingConfirmedCandidateHasOneCountAndRestoresPreviousDecisionOnUndo() {
        let first = sample()
        let second = sample()
        let person = UUID()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.confirmed(person), for: first.id, undoID: UUID())
        session.selectCandidate(first.id)
        session.correct(.rejected, for: first.id, undoID: UUID())
        #expect(session.decidedCount == 1 && session.remainingCount == 1)
        #expect(session.decisions[first.id] == .rejected && session.candidateID == second.id)
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.decisions[first.id] == .confirmed(person) && session.displayedID == first.id)
        #expect(session.decidedCount == 1 && session.history.count == 1)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func reviewActionAvailabilityKeepsConfirmedAndSkippedStatesSafe() {
        let person = UUID()
        let pending = sample()
        let pendingActions = VoiceMatchReviewSession.actions(
            for: pending, decision: nil, isReference: false, personID: person)
        #expect(pendingActions.canSkip && pendingActions.canConfirm && pendingActions.canReject)
        let skipped = VoiceMatchReviewSession.actions(
            for: pending, decision: .skipped, isReference: false, personID: person)
        #expect(!skipped.canSkip && skipped.canConfirm && skipped.canReject)
        var confirmed = pending
        confirmed.personID = person
        confirmed.review = .confirmed
        for reference in [false, true] {
            let actions = VoiceMatchReviewSession.actions(
                for: confirmed, decision: .confirmed(person), isReference: reference, personID: person)
            #expect(!actions.canSkip && !actions.canConfirm && actions.canReject)
        }
        confirmed.personID = UUID()
        let other = VoiceMatchReviewSession.actions(for: confirmed, decision: nil, isReference: false, personID: person)
        #expect(!other.canSkip && !other.canConfirm && !other.canReject)
    }

    @Test func skippedCandidateCanBeConfirmedLaterAndUndoRestoresSkip() {
        let first = sample()
        let second = sample()
        let person = UUID()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.skipped, for: first.id, undoID: nil)
        session.selectCandidate(first.id)
        session.correct(.confirmed(person), for: first.id, undoID: UUID())
        #expect(session.decidedCount == 1 && session.skippedCount == 0 && session.displayedID == second.id)
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.decidedCount == 0 && session.skippedCount == 1 && session.displayedID == first.id)
    }

    @Test func refreshingCompletedQueueSelectsNewAudioWithoutAppendingAnAlias() {
        var first = sample()
        first.audioRevision = "synthetic"
        var alias = first
        alias.id = UUID()
        let newAudio = sample()
        var session = VoiceMatchReviewSession(examples: [first])
        session.record(.ignored, for: first.id, undoID: UUID())
        session.refreshQueue([alias, newAudio], currentEvidence: [first, alias, newAudio])
        #expect(session.examples.map(\.id) == [first.id, newAudio.id])
        #expect(session.displayedID == newAudio.id && session.remainingCount == 1)
    }

    @Test func queueRefreshUsesCurrentEvidenceAndDisablesDeletedRows() {
        let first = sample()
        let deleted = sample()
        let newAudio = sample()
        var updated = first
        updated.namedPersonID = UUID()
        updated.review = .suggested
        var session = VoiceMatchReviewSession(examples: [first, deleted])
        session.selectCandidate(deleted.id)
        session.refreshQueue([newAudio], currentEvidence: [updated, newAudio])
        #expect(session.examples.first?.namedPersonID == updated.namedPersonID)
        #expect(session.unavailableIDs == [deleted.id])
        #expect(session.displayedID == deleted.id)
        #expect(session.remainingCount == 2)
        session.refreshQueue([deleted], currentEvidence: [updated, deleted, newAudio])
        #expect(session.unavailableIDs.isEmpty && session.examples.count == 3)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func skippedUnnamedSampleCanNamePersonAndUndoRestoresSkippedState() {
        let first = sample()
        let second = sample()
        let person = UUID()
        var session = VoiceMatchReviewSession(examples: [first, second])
        session.record(.skipped, for: first.id, undoID: nil)
        session.selectCandidate(first.id)
        session.recordNaming(
            personID: person, confirmedExampleID: first.id, updatedExamples: [first, second], undoID: UUID())
        #expect(session.personID == person && session.decisions[first.id] == .confirmed(person))
        #expect(session.decidedCount == 1 && session.skippedCount == 0 && session.displayedID == second.id)
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.personID == nil && session.decisions[first.id] == .skipped)
        #expect(session.decidedCount == 0 && session.skippedCount == 1 && session.displayedID == first.id)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func ignoredAndRejectedRowsExposeCorrectionsWithinTheCurrentSession() {
        let person = UUID()
        var previouslyConfirmed = sample()
        previouslyConfirmed.personID = person
        previouslyConfirmed.review = .confirmed
        previouslyConfirmed.excluded = true
        for decision in [VoiceMatchReviewSession.Decision.ignored, .rejected] {
            let actions = VoiceMatchReviewSession.actions(
                for: previouslyConfirmed, decision: decision, isReference: false, personID: person)
            #expect(actions.canConfirm && !actions.canSkip)
            #expect(actions.canReject == (decision != .rejected))
            #expect(!actions.canIgnore)
        }
        let first = sample()
        let second = sample()
        var session = VoiceMatchReviewSession(examples: [first, second], personID: person)
        session.record(.ignored, for: first.id, undoID: UUID())
        session.record(.confirmed(person), for: second.id, undoID: UUID())
        session.selectCandidate(first.id)
        session.correct(.rejected, for: first.id, undoID: UUID())
        #expect(session.decidedCount == 2 && session.remainingCount == 0)
        #expect(session.decisions[second.id] == .confirmed(person))
        session.restoreLast(updatedExamples: [first, second])
        #expect(session.decisions[first.id] == .ignored && session.displayedID == first.id)
        #expect(session.decisions[second.id] == .confirmed(person))
    }

    @Test func ignoredUnnamedRowCanBeNamedAndUndoRestoresItsDecision() {
        let first = sample()
        let other = sample()
        let person = UUID()
        var session = VoiceMatchReviewSession(examples: [first, other])
        session.record(.ignored, for: first.id, undoID: UUID())
        session.selectCandidate(first.id)
        session.recordNaming(
            personID: person, confirmedExampleID: first.id, updatedExamples: [first, other], undoID: UUID())
        #expect(session.personID == person && session.decisions[first.id] == .confirmed(person))
        session.restoreLast(updatedExamples: [first, other])
        #expect(session.personID == nil && session.decisions[first.id] == .ignored)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func alternateRemainsNamingEvidenceWhenSnapshotKeepsItInADifferentGroup() {
        let first = sample()
        let alternate = sample()
        let group = VoiceIdentificationGroup(id: first.groupID, examples: [first], representativeID: first.id)
        let otherGroup = VoiceIdentificationGroup(
            id: alternate.groupID, examples: [alternate], representativeID: alternate.id)
        var session = VoiceMatchReviewSession(examples: [first])
        session.showAlternative(alternate, currentEvidence: [first, alternate])
        var retained = [first, alternate]
        let snapshot = VoiceReviewSnapshot(revision: 2, candidates: [:], unnamedGroups: [group, otherGroup])
        for _ in 0..<2 {
            let input = session.refreshInput(
                from: snapshot, initialGroup: group, fallbackPersonID: nil, retainedGroupEvidence: retained,
                currentEvidence: [first, alternate])
            retained = input.groupEvidence
            session.refreshQueue(input.examples, currentEvidence: [first, alternate])
            #expect(retained.map(\.id) == [first.id, alternate.id])
            #expect(session.displayedID == alternate.id)
        }
        let person = UUID()
        session.recordNaming(
            personID: person, confirmedExampleID: alternate.id,
            updatedExamples: [first, alternate], undoID: UUID())
        #expect(session.personID == person && session.decisions[alternate.id] == .confirmed(person))
        session.restoreLast(updatedExamples: [first, alternate])
        #expect(session.personID == nil && session.displayedID == alternate.id)
    }

    @Test func currentDecisionCannotBeRepeatedButOtherCorrectionsRemainAvailable() {
        let person = UUID()
        let example = sample()
        let ignored = VoiceMatchReviewSession.actions(
            for: example, decision: .ignored, isReference: false, personID: person)
        #expect(!ignored.canIgnore && ignored.canReject && ignored.canConfirm)
        let rejected = VoiceMatchReviewSession.actions(
            for: example, decision: .rejected, isReference: false, personID: person)
        #expect(rejected.canIgnore && !rejected.canReject && rejected.canConfirm)
    }
}

extension VoiceMatchReviewSessionTests {
    @Test func alternateNamingEvidenceUsesExternalChangesAndDropsDeletedSamples() {
        let first = sample()
        let alternate = sample()
        let group = VoiceIdentificationGroup(id: first.groupID, examples: [first], representativeID: first.id)
        var session = VoiceMatchReviewSession(examples: [first])
        session.showAlternative(alternate, currentEvidence: [first, alternate])
        var changed = alternate
        changed.excluded = true
        changed.rejectedPersonIDs = [UUID()]
        let snapshot = VoiceReviewSnapshot(revision: 2, candidates: [:], unnamedGroups: [group])
        let refreshed = session.refreshInput(
            from: snapshot, initialGroup: group, fallbackPersonID: nil,
            retainedGroupEvidence: [first, alternate], currentEvidence: [first, changed])
        #expect(refreshed.groupEvidence.first { $0.id == alternate.id } == changed)
        session.refreshQueue(refreshed.examples, currentEvidence: [first, changed])
        #expect(session.examples.first { $0.id == alternate.id } == changed)
        #expect(session.displayedID == alternate.id && session.unavailableIDs.isEmpty)
        let removed = session.refreshInput(
            from: snapshot, initialGroup: group, fallbackPersonID: nil,
            retainedGroupEvidence: refreshed.groupEvidence, currentEvidence: [first])
        #expect(removed.groupEvidence.map(\.id) == [first.id])
        session.refreshQueue(removed.examples, currentEvidence: [first])
        #expect(session.displayedID == alternate.id && session.unavailableIDs.contains(alternate.id))
        #expect(session.decisions.isEmpty && session.history.isEmpty)
    }
}
