import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReviewSelectionTests {
    let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")

    func sample(_ similarity: Double, person: UUID? = nil) -> VoiceExample {
        VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "fixture", start: 0, end: 4, personID: person,
            review: person == nil ? .unassigned : .confirmed,
            embeddings: [.init(type: type, values: [similarity, sqrt(1 - similarity * similarity)])])
    }

    @Test func exactAudioIdentityKeepsDifferentSourcesRevisionsAndUnroundedSpans() {
        let first = sample(0.8)
        var alias = first
        alias.id = UUID()
        alias.groupID = UUID()
        #expect(VoiceReviewSelection.sameAudio(first, alias))
        let groups = VoiceIdentificationSelection.groups([first, alias])
        #expect(groups.flatMap(\.examples).count == 1)
        #expect(Set(groups.flatMap(\.evidenceExamples).map(\.id)) == [first.id, alias.id])
        var source = alias
        source.source = "microphone"
        var revision = alias
        revision.audioRevision = "replaced"
        var shifted = alias
        shifted.start = 0.01
        var unknown = alias
        unknown.audioRevision = nil
        for distinct in [source, revision, shifted, unknown] {
            #expect(!VoiceReviewSelection.sameAudio(first, distinct))
        }
        #expect(VoiceIdentificationSelection.groups([first, shifted]).flatMap(\.examples).count == 2)
        let seed = sample(1, person: UUID())
        #expect(VoiceReviewSelection.rank([seed, first, source], for: seed.personID!).count == 2)
    }

    @Test func exactAudioRetainsConflictingHumanIdentityDecisions() {
        let person = UUID()
        let first = sample(1, person: person)
        var conflicting = first
        conflicting.id = UUID()
        conflicting.personID = UUID()
        var named = first
        named.id = UUID()
        named.personID = nil
        named.review = .suggested
        named.namedPersonID = UUID()
        var rejected = first
        rejected.id = UUID()
        rejected.personID = nil
        rejected.review = .rejected
        rejected.rejectedPersonIDs = [person]
        let examples = [first, conflicting, named, rejected]
        #expect(
            Set(VoiceIdentificationSelection.groups(examples).flatMap(\.examples).map(\.id)) == Set(examples.map(\.id)))
    }

    @Test func compatibleRejectedAliasDecisionsStillProduceOneQuestionForOtherPeople() {
        let person = UUID()
        let seed = sample(1, person: person)
        let first = sample(0.8)
        var alias = first
        alias.id = UUID()
        alias.rejectedPersonIDs = [UUID()]
        alias.review = .rejected
        #expect(VoiceReviewSelection.rank([seed, first, alias], for: person).count == 1)
    }

    @Test func reviewIncludesBoundaryAndAmbiguousEvidenceWithoutChangingRecognition() {
        let person = UUID()
        let seed = sample(1, person: person)
        let boundary = sample(0.79)
        let easy = sample(0.999)
        let unrelated = sample(0.20)
        let ranked = VoiceReviewSelection.rank([seed, easy, unrelated, boundary], for: person)
        #expect(ranked.map(\.id) == [boundary.id, easy.id])
        let profile = Person(
            id: person,
            voiceSamples: [
                .init(meetingID: seed.meetingID, speakerID: seed.id, voiceEmbedding: seed.embeddings[0])
            ])
        #expect(SpeakerRecognition.match(embedding: boundary.embeddings[0], people: [profile]) == nil)
        let competitor = sample(0.9, person: UUID())
        let ambiguous = sample(0.95)
        #expect(VoiceReviewSelection.rank([seed, competitor, ambiguous], for: person).map(\.id) == [ambiguous.id])
    }

    @Test func measuredSignalIssueRanksBelowUnassessedCandidateDespiteHigherMatchPriority() {
        let person = UUID()
        let seed = sample(1, person: person)
        var boundary = sample(0.80)
        let easy = sample(0.999)
        boundary.sampleQuality = VoiceSampleQuality.assess(
            range: boundary.range!, audioRevision: boundary.audioRevision!, scanConfiguration: "synthetic-scan-v1",
            samples: [Float](repeating: 0, count: 64000))
        let ranked = VoiceReviewSelection.rank([seed, easy, boundary], for: person)
        #expect(ranked.map(\.id) == [easy.id, boundary.id])
    }

    @Test func excludesDecisionsJunkAndRedundantExcerptsButKeepsDifferentPeopleEligible() {
        let person = UUID()
        let seed = sample(1, person: person)
        let candidate = sample(0.8)
        var duplicate = candidate
        duplicate.id = UUID()
        duplicate.start = 0.1
        var rejected = sample(0.8)
        rejected.review = .rejected
        rejected.rejectedPersonIDs = [person]
        var rejectedOther = sample(0.8)
        rejectedOther.review = .rejected
        rejectedOther.rejectedPersonIDs = [UUID()]
        var excluded = sample(0.8)
        excluded.excluded = true
        var cleared = sample(0.8)
        cleared.manuallyCleared = true
        var unavailable = sample(0.8)
        unavailable.audioFile = nil
        var short = sample(0.8)
        short.end = 0.1
        var invalid = sample(0.8)
        invalid.embeddings = [.init(type: type, values: [0, 0])]
        let result = VoiceReviewSelection.rank(
            [seed, candidate, duplicate, rejected, rejectedOther, excluded, cleared, unavailable, short, invalid],
            for: person)
        #expect(result.count == 2)
        #expect(result.contains { $0.id == rejectedOther.id })
        #expect(result.contains { $0.id == candidate.id || $0.id == duplicate.id })
    }

    @Test func reviewEvidenceIgnoresAutomaticSuggestionsAndRejectsChangedDecisionsOrAudio() {
        let original = sample(0.8)
        var changed = original
        changed.suggestedPersonID = UUID()
        changed.review = .suggested
        changed.embeddings = []
        #expect(changed.hasSameReviewEvidence(as: original))
        changed.rejectedPersonIDs = [UUID()]
        #expect(!changed.hasSameReviewEvidence(as: original))
        changed = original
        changed.personID = UUID()
        changed.review = .confirmed
        #expect(!changed.hasSameReviewEvidence(as: original))
        changed = original
        changed.start = 1
        #expect(!changed.hasSameReviewEvidence(as: original))
        changed = original
        changed.audioRevision = "replacement"
        #expect(!changed.hasSameReviewEvidence(as: original))
    }

    @Test func isolatedLibrariesNeverUseSharedKeychain() {
        #expect(KeychainStore.isIsolated(environment: ["GDAY_SWIFT_DATA_DIR": "/tmp/synthetic"], preview: false))
        #expect(KeychainStore.isIsolated(environment: [:], preview: true))
        #expect(!KeychainStore.isIsolated(environment: [:], preview: false))
    }
}

extension VoiceReviewSelectionTests {
    @Test func explicitlyAssociatedExcerptsRemainPendingWithoutAcousticSamplingOrProfileSeed() {
        let person = UUID()
        let first = sample(0.99)
        var associated = first
        associated.namedPersonID = person
        associated.suggestedPersonID = person
        associated.review = .suggested
        var next = associated
        next.id = UUID()
        next.start = 10
        next.end = 14
        var alias = associated
        alias.id = UUID()
        alias.groupID = UUID()
        let queue = VoiceReviewSelection.rank([associated, alias, next], for: person, limit: 1)
        #expect(queue.count == 2)
        #expect(queue.contains { $0.id == next.id })
        #expect(queue.filter { VoiceReviewSelection.sameAudio($0, associated) }.count == 1)
        var confirmed = associated
        confirmed.personID = person
        confirmed.namedPersonID = nil
        confirmed.review = .confirmed
        let afterConfirmation = VoiceReviewSelection.rank([confirmed, alias, next], for: person, limit: 1)
        #expect(afterConfirmation.map(\.id) == [next.id])
        var rejected = next
        rejected.namedPersonID = nil
        rejected.suggestedPersonID = nil
        rejected.review = .rejected
        rejected.rejectedPersonIDs = [person]
        #expect(VoiceReviewSelection.rank([confirmed, alias, rejected], for: person).isEmpty)
    }
}
