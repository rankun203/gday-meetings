import Foundation
import Testing

@testable import GdayMeetings

struct TypedVoiceEmbeddingTests {
    let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "clean-v1", dimension: 2, normalization: "unitL2")

    @Test func knownRunPodSamplesShareCommunityModelSpaceAndNormalize() throws {
        let raw = [2.0] + Array(repeating: 0.0, count: 255)
        for provenance in ["legacy:rust:runpod", "runpod:https://worker.example/v2/synthetic"] {
            let sample = PersonVoiceSample(meetingID: UUID(), speakerID: UUID(), scope: provenance, embedding: raw)
            let resolved = sample.resolvedVoiceEmbedding
            #expect(resolved.type == .community1 && resolved.isValid)
            #expect(resolved.values[0] == 1)
            let person = Person(name: "Synthetic person", voiceSamples: [sample])
            let local = TypedVoiceEmbedding(type: .community1, values: [1] + Array(repeating: 0, count: 255))
            #expect(SpeakerRecognition.match(embedding: local, people: [person])?.personID == person.id)
        }
        let unknown = TypedVoiceEmbedding(type: .unknownLegacy(dimension: 256), values: raw, provenance: "legacy:rust")
        #expect(!unknown.isValid)
        let short = TypedVoiceEmbedding(
            type: .unknownLegacy(dimension: 2), values: [1, 0], provenance: "legacy:rust:runpod")
        #expect(!short.isValid)
        var other = EmbeddingType.community1
        other.modelID = "synthetic-different-model"
        let explicit = TypedVoiceEmbedding(type: other, values: raw, provenance: "legacy:rust:runpod")
        #expect(explicit.type == other)
    }

    @Test func decodingOldKnownRunPodRepresentationUsesRegisteredAlias() throws {
        let old: [String: Any] = [
            "type": [
                "modelID": "unknown", "revision": "unknown", "compatibilityVersion": "unknown", "dimension": 256,
                "normalization": "unknown",
            ],
            "values": [3.0] + Array(repeating: 0.0, count: 255), "provenance": "legacy:rust:runpod",
        ]
        let decoded = try JSONDecoder().decode(
            TypedVoiceEmbedding.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.type == .community1 && decoded.isValid)
    }

    @Test func unknownLegacySamplesRoundTripButCannotMatch() throws {
        let sample = PersonVoiceSample(
            meetingID: UUID(), speakerID: UUID(), scope: "synthetic:endpoint", embedding: [1, 0])
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(PersonVoiceSample.self, from: encoded)
        #expect(decoded == sample)
        #expect(decoded.resolvedVoiceEmbedding.type == .unknownLegacy(dimension: 2))
        let person = Person(name: "Alex", voiceSamples: [sample])
        #expect(SpeakerRecognition.match(embedding: .init(type: type, values: [1, 0]), people: [person]) == nil)
    }

    @Test func compatibilityUsesEveryTypeFieldAndRejectsInvalidNormalization() throws {
        let embedding = try #require(TypedVoiceEmbedding.normalizing(type: type, values: [2, 0]))
        let person = Person(
            name: "Alex", voiceSamples: [.init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: embedding)])
        #expect(SpeakerRecognition.match(embedding: embedding, people: [person])?.personID == person.id)
        var variants = [type, type, type, type, type]
        variants[0].modelID = "other"
        variants[1].revision = "v2"
        variants[2].compatibilityVersion = "clean-v2"
        variants[3].dimension = 3
        variants[4].normalization = "raw"
        for variant in variants {
            #expect(SpeakerRecognition.match(embedding: .init(type: variant, values: [1, 0]), people: [person]) == nil)
        }
        #expect(SpeakerRecognition.match(embedding: .init(type: type, values: [2, 0]), people: [person]) == nil)
        #expect(TypedVoiceEmbedding.normalizing(type: type, values: [.nan, 1]) == nil)
        #expect(TypedVoiceEmbedding.normalizing(type: type, values: [0, 0]) == nil)
    }

    @Test func marginRejectsAmbiguityAndMixedProfilesRetainIndependentTypes() throws {
        let embedding = try #require(TypedVoiceEmbedding.normalizing(type: type, values: [1, 0]))
        var other = type
        other.revision = "v2"
        let unrelated = TypedVoiceEmbedding(type: other, values: [0, 1])
        let first = Person(
            name: "Alex",
            voiceSamples: [
                .init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: embedding),
                .init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: unrelated),
            ])
        let second = Person(
            name: "Sam", voiceSamples: [.init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: embedding)])
        #expect(SpeakerRecognition.match(embedding: embedding, people: [first])?.score == 1)
        #expect(SpeakerRecognition.match(embedding: embedding, people: [first, second]) == nil)
        #expect(SpeakerRecognition.match(embedding: unrelated, people: [first])?.personID == first.id)
        #expect(
            try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(first)).voiceSamples == first.voiceSamples)
    }
}
