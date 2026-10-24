import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReferenceAdmissionTests {
    private func type(_ dimension: Int, revision: String = "1") -> EmbeddingType {
        .init(
            modelID: "synthetic-reference", revision: revision, compatibilityVersion: "1", dimension: dimension,
            normalization: "unitL2")
    }

    private func sample(_ index: Int, _ embedding: TypedVoiceEmbedding) -> PersonVoiceSample {
        .init(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            speakerID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            voiceEmbedding: embedding)
    }

    private func example(_ sample: PersonVoiceSample, duration: Double = 3) -> VoiceExample {
        .init(
            id: sample.speakerID, meetingID: sample.meetingID, speakerID: sample.speakerID, source: "microphone",
            audioFile: "microphone.wav", audioRevision: "synthetic", start: 0, end: duration,
            embeddings: [sample.resolvedVoiceEmbedding])
    }

    @Test func fullProfileAdmitsComplementaryReferenceAndStillSuppressesDuplicates() {
        let model = type(2)
        let existing = TypedVoiceEmbedding(type: model, values: [1, 0])
        let person = Person(name: "Person A", voiceSamples: (0..<12).map { sample($0, existing) })
        let complementary = TypedVoiceEmbedding(type: model, values: [0.8, 0.6])
        #expect(
            VoiceReferenceSelection.rejection(
                embedding: complementary, personID: person.id, profiles: [person],
                candidate: example(sample(20, complementary)),
                referenceExamples: person.voiceSamples.map { example($0) })
                == nil)
        #expect(
            VoiceReferenceSelection.rejection(embedding: existing, personID: person.id, profiles: [person])
                == .alreadyRepresented)
        #expect(person.voiceSamples.count == 12)
    }

    @Test func fullProfileDoesNotRetainAnotherEquallyUsefulReference() {
        let model = type(14)
        func embedding(_ index: Int) -> TypedVoiceEmbedding {
            var values = [Double](repeating: 0, count: model.dimension)
            values[0] = 0.8
            values[index + 1] = 0.6
            return .init(type: model, values: values)
        }
        let person = Person(name: "Person A", voiceSamples: (0..<12).map { sample($0, embedding($0)) })
        var candidate = example(sample(20, embedding(12)))
        candidate.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        #expect(
            VoiceReferenceSelection.rejection(
                embedding: embedding(12), personID: person.id, profiles: [person], candidate: candidate,
                referenceExamples: person.voiceSamples.map { example($0) })
                == .alreadyRepresented)
        candidate.end = 0.1
        candidate.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        #expect(
            VoiceReferenceSelection.rejection(
                embedding: embedding(12), personID: person.id, profiles: [person], candidate: candidate,
                referenceExamples: person.voiceSamples.map { example($0) })
                == .alreadyRepresented)
    }

    @Test func fullProfileRequiresRealSupportMetadataBeforeReplacingAReference() {
        let model = type(2)
        let existing = TypedVoiceEmbedding(type: model, values: [1, 0])
        let person = Person(name: "Person A", voiceSamples: (0..<12).map { sample($0, existing) })
        let complementary = TypedVoiceEmbedding(type: model, values: [0.8, 0.6])
        #expect(
            VoiceReferenceSelection.rejection(embedding: complementary, personID: person.id, profiles: [person])
                == .insufficientEvidence)
    }

    @Test func differentModelsHaveIndependentBudgetsAndRivalEvidenceStillVetoesEnrollment() {
        let model = type(2)
        let existing = TypedVoiceEmbedding(type: model, values: [1, 0])
        let candidate = TypedVoiceEmbedding(type: model, values: [0.8, 0.6])
        let person = Person(name: "Person A", voiceSamples: (0..<12).map { sample($0, existing) })
        let rival = Person(name: "Person B", voiceSamples: [sample(20, candidate)])
        #expect(
            VoiceReferenceSelection.rejection(embedding: candidate, personID: person.id, profiles: [person, rival])
                == .conflictingEvidence)
        var otherModel = candidate
        otherModel.type = type(2, revision: "2")
        #expect(
            VoiceReferenceSelection.rejection(embedding: otherModel, personID: person.id, profiles: [person]) == nil)
    }
}
