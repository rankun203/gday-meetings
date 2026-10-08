import Foundation
import Testing

@testable import GdayMeetings

struct MeetingSpeakerCodingTests {
    private struct LegacySpeaker: Decodable {
        var id: UUID
        var embedding: [Double]?
        var voiceEmbedding: TypedVoiceEmbedding?
        var voiceSampleRange: LegacyRange?
        var canImportVoice: Bool { embedding != nil || voiceEmbedding != nil || voiceSampleRange?.isValid == true }
    }
    private struct LegacyRange: Decodable {
        var start: Double
        var end: Double
        var isValid: Bool { start >= 0 && end > start }
    }
    private func vector(_ provenance: String? = nil) -> TypedVoiceEmbedding {
        .normalizing(
            type: .init(
                modelID: "test", revision: "1", compatibilityVersion: "1", dimension: 2,
                normalization: "unitL2"), values: [1, 0], provenance: provenance)!
    }
    private func richSpeaker() -> MeetingSpeaker {
        var value = MeetingSpeaker(label: "Person", track: "microphone", providerName: "local")
        value.voiceScope = "source"
        value.embedding = [1, 0]
        value.voiceEmbedding = vector()
        value.personID = UUID()
        value.confidence = 0.92
        value.confirmed = true
        value.sourcePlaceholder = .microphone
        value.voiceSampleRange = .init(audioFile: "microphone.wav", source: "microphone", start: 2, end: 5)
        value.voiceSampleRevision = "revision"
        value.manuallyAssigned = true
        value.manualReviewThrough = ["microphone": 100]
        value.voiceReviewOrigin = .init(
            speakerID: UUID(), personID: UUID(), manuallyAssigned: true, confidence: 0.9,
            manualReviewThrough: ["system": 42])
        value.voiceReviewExampleID = UUID()
        value.colorSlot = 7
        value.passageAssignmentOrigin = .init(
            speakerID: UUID(), speaker: "old", personID: UUID(),
            associationUncertain: true, speakerPersonID: UUID(), labelDecisionChanged: true)
        return value
    }
    @Test func allFieldsRoundTripForContiguousAndFragmentedEvidence() throws {
        var speaker = richSpeaker()
        let plain = try JSONEncoder().encode(speaker)
        #expect(try JSONDecoder().decode(MeetingSpeaker.self, from: plain) == speaker)
        #expect(try JSONDecoder().decode(LegacySpeaker.self, from: plain).canImportVoice)
        speaker.voiceSampleRange = .init(
            audioFile: "microphone.wav", source: "microphone", start: 0, end: 21,
            spans: [.init(start: 0, end: 1), .init(start: 20, end: 21)])
        let fragmented = try JSONEncoder().encode(speaker)
        #expect(try JSONDecoder().decode(MeetingSpeaker.self, from: fragmented) == speaker)
        let old = try JSONDecoder().decode(LegacySpeaker.self, from: fragmented)
        #expect(old.embedding == nil && old.voiceEmbedding == nil)
        #expect(!old.canImportVoice)
    }
    @Test func liveAndReextractedFragmentsRemainProtectedWithoutSavedRange() throws {
        for provenance in ["saved-example-clean-fragments-v1"] {
            var speaker = richSpeaker()
            speaker.voiceSampleRange = nil
            speaker.voiceEmbedding = vector(provenance)
            let data = try JSONEncoder().encode(speaker)
            #expect(try JSONDecoder().decode(MeetingSpeaker.self, from: data) == speaker)
            let old = try JSONDecoder().decode(LegacySpeaker.self, from: data)
            #expect(!old.canImportVoice)
        }
    }
    @Test func missingRequiredIdentityAndConflictingRepresentations() throws {
        let minimal = Data(#"{"label":"Speaker","track":"system","providerName":"old"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MeetingSpeaker.self, from: minimal) }
        var value = richSpeaker()
        value.voiceEmbedding = vector("saved-example-clean-fragments-v1")
        let data = try JSONEncoder().encode(value)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["embedding"] = [0, 1]
        let conflicting = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MeetingSpeaker.self, from: conflicting) }
    }
}
