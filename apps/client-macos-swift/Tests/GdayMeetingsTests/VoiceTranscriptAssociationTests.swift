import Foundation
import Testing

@testable import GdayMeetings

struct VoiceTranscriptAssociationTests {
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "one", compatibilityVersion: "one", dimension: 2, normalization: "unitL2")

    private func sample(score: Double, personID: UUID? = nil) -> VoiceExample {
        VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic", start: 0, end: 4, personID: personID,
            review: personID == nil ? .unassigned : .confirmed,
            embeddings: [.init(type: type, values: [score, sqrt(1 - score * score)])])
    }

    private func run(
        examples: [VoiceExample], people: [Person], policy: VoiceMatchingPolicy = .default
    ) async throws -> VoiceMatchingWorker.Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try VoiceLibraryPersistence(directory: directory)
        _ = try backend.load()
        var document = VoiceLibraryDocument()
        document.examples = examples
        try backend.commit(previous: VoiceLibraryDocument(), next: document)
        return try await VoiceMatchingWorker().run(
            .init(
                directory: directory, persistence: backend.snapshot(), examples: examples, people: people,
                deletedPeople: [], includeSuggestions: true, policy: policy),
            beforeRead: nil, beforeValidation: nil)
    }

    @Test func confidentCandidateCarriesReversibleAttributionWithoutTrainingEvidence() async throws {
        let person = Person(name: "Example Person")
        let reference = sample(score: 1, personID: person.id)
        var candidate = sample(score: 0.81)
        candidate.review = .suggested
        candidate.suggestedPersonID = person.id
        candidate.transcriptAssociation = .init(personID: person.id, score: 0.81, margin: 1.81, policy: .default)
        let result = try await run(examples: [reference, candidate], people: [person])
        let association = try #require(result.suggestions.first?.transcriptAssociation)
        #expect(association.personID == person.id)
        #expect(abs(association.score - 0.81) < 1e-12)
        #expect(association.isValid)
        #expect(result.profiles[0].voiceSamples.map(\.speakerID) == [reference.id])
        #expect(candidate.personID == nil && candidate.needsReview)
    }

    @Test func explicitStricterPolicyIsPreserved() async throws {
        let person = Person(name: "Example Person")
        let policy = VoiceMatchingPolicy(automaticThreshold: 0.85)
        let result = try await run(
            examples: [sample(score: 1, personID: person.id), sample(score: 0.81)], people: [person], policy: policy)
        #expect(result.suggestions.count == 1)
        #expect(result.suggestions[0].personID == nil)
        #expect(result.suggestions[0].transcriptAssociation == nil)
        #expect(try JSONDecoder().decode(VoiceMatchingPolicy.self, from: JSONEncoder().encode(policy)) == policy)
    }

    @Test func strongSimilarityWithoutRequiredLeadStaysUnassociated() async throws {
        let first = Person(name: "Example Person A")
        let second = Person(name: "Example Person B")
        let candidate = sample(score: 1)
        let result = try await run(
            examples: [sample(score: 0.92, personID: first.id), sample(score: 0.90, personID: second.id), candidate],
            people: [first, second])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func rejectedPersonCannotBecomeAnAutomaticAssociation() async throws {
        let person = Person(name: "Example Person")
        var candidate = sample(score: 1)
        candidate.review = .rejected
        candidate.rejectedPersonIDs = [person.id]
        let result = try await run(examples: [sample(score: 1, personID: person.id), candidate], people: [person])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func incompatibleRepresentationCannotBecomeAnAutomaticAssociation() async throws {
        let person = Person(name: "Example Person")
        var candidate = sample(score: 1)
        candidate.embeddings[0].type.revision = "other"
        let result = try await run(examples: [sample(score: 1, personID: person.id), candidate], people: [person])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func separatedLowSimilarityBecomesTentativeWithoutAddingAReviewSuggestion() async throws {
        let first = Person(name: "Example Person A")
        let second = Person(name: "Example Person B")
        let result = try await run(
            examples: [
                sample(score: 0.40, personID: first.id), sample(score: 0.01, personID: second.id), sample(score: 1),
            ],
            people: [first, second])
        let suggestion = try #require(result.suggestions.first)
        let association = try #require(suggestion.transcriptAssociation)
        #expect(association.personID == first.id && association.tier == .tentative && association.isValid)
        #expect(abs(association.score - 0.40) < 1e-12 && abs(association.margin - 0.39) < 1e-12)
        #expect(suggestion.personID == nil)
        #expect(result.profiles.allSatisfy { $0.voiceSamples.count == 1 })
    }

    @Test func lowSimilarityWithOnlyOneComparablePersonStaysUnresolved() async throws {
        let first = Person(name: "Example Person A")
        let incompatible = Person(name: "Example Person B")
        var otherReference = sample(score: 0.01, personID: incompatible.id)
        otherReference.embeddings[0].type.revision = "other"
        let result = try await run(
            examples: [sample(score: 0.4, personID: first.id), otherReference, sample(score: 1)],
            people: [first, incompatible])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func equallyPlausiblePeopleStayUnresolved() async throws {
        let first = Person(name: "Example Person A")
        let second = Person(name: "Example Person B")
        let result = try await run(
            examples: [
                sample(score: 0.4, personID: first.id), sample(score: 0.4, personID: second.id), sample(score: 1),
            ],
            people: [first, second])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func rejectedCompetitorDoesNotSupplyArtificialTentativeSeparation() async throws {
        let first = Person(name: "Example Person A")
        let second = Person(name: "Example Person B")
        var candidate = sample(score: 1)
        candidate.rejectedPersonIDs = [second.id]
        candidate.review = .rejected
        let result = try await run(
            examples: [sample(score: 0.4, personID: first.id), sample(score: 0.01, personID: second.id), candidate],
            people: [first, second])
        #expect(result.suggestions.first?.transcriptAssociation == nil)
    }

    @Test func manualClearAndConfirmedIdentityStayOutsideMachineRecomputation() async throws {
        let first = Person(name: "Example Person A")
        let second = Person(name: "Example Person B")
        var cleared = sample(score: 1)
        cleared.manuallyCleared = true
        let result = try await run(
            examples: [sample(score: 1, personID: first.id), sample(score: 0.01, personID: second.id), cleared],
            people: [first, second])
        #expect(result.suggestions.isEmpty)
    }

    @Test func olderExamplesAndUndoDecodeWithoutNewMachineMetadata() throws {
        let example = sample(score: 1)
        let encoded = try JSONEncoder().encode(example)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "transcriptAssociation")
        object.removeValue(forKey: "detectedSpeakerID")
        object.removeValue(forKey: "detectedSpeakerSpans")
        let decoded = try JSONDecoder().decode(VoiceExample.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.transcriptAssociation == nil && decoded.detectedSpeakerSpans == nil)
        let snapshot = VoiceExampleReviewSnapshot(example)
        let restored = try JSONDecoder().decode(
            VoiceExampleReviewSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
    }

    @Test func undoRestoresMachineAttributionWithoutPromotingItToConfirmation() {
        let person = UUID()
        var candidate = sample(score: 0.81)
        candidate.transcriptAssociation = .init(personID: person, score: 0.81, margin: 1.81, policy: .default)
        let snapshot = VoiceExampleReviewSnapshot(candidate)
        candidate.personID = person
        candidate.review = .confirmed
        candidate.transcriptAssociation = nil
        snapshot.restore(&candidate)
        #expect(candidate.transcriptAssociation?.personID == person)
        #expect(candidate.personID == nil && candidate.review == .unassigned)
    }

    @Test func defaultAndInvalidPolicyUseAcceptedAutomaticThreshold() {
        #expect(
            VoiceMatchingPolicy.default
                == .init(suggestionThreshold: 0.55, automaticThreshold: 0.80, minimumMargin: 0.08))
        #expect(VoiceMatchingPolicy(automaticThreshold: .nan).normalized.automaticThreshold == 0.80)
        let invalid = VoiceTranscriptAssociation(personID: UUID(), score: .nan, margin: 0.1, policy: .default)
        #expect(!invalid.isValid)
    }
}
