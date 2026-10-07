import Foundation
import Testing

@testable import GdayMeetings

struct VoiceProfileMatchingTests {
    private func embedding(_ values: [Double]) -> TypedVoiceEmbedding {
        TypedVoiceEmbedding.normalizing(
            type: .init(
                modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                dimension: values.count, normalization: "unitL2"), values: values)!
    }

    @Test func distinctReviewedModesMatchWithoutAveragingThem() {
        var person = Person(name: "Alex")
        person.voiceSamples = [[1.0, 0], [0.0, 1]].map {
            PersonVoiceSample(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: embedding($0))
        }
        let query = embedding([1, 0])
        #expect(SpeakerRecognition.match(embedding: query, people: [person])?.personID == person.id)
        var speakers = (0..<2).map {
            MeetingSpeaker(
                label: "speaker_\($0)", track: "microphone", providerName: "Synthetic", voiceEmbedding: query)
        }
        SpeakerRecognition.match(&speakers, people: [person])
        #expect(speakers.allSatisfy { $0.personID == person.id })
        var competing = Person(name: "Sam")
        competing.voiceSamples = person.voiceSamples
        #expect(SpeakerRecognition.match(embedding: query, people: [person, competing]) == nil)
    }

    @Test func invalidProfileRepresentativesAreRejected() {
        var invalid = embedding([1, 0])
        invalid.type.revision = "unknown"
        let sample = SpeakerEvidenceSample(
            id: "invalid", source: "microphone", localSpeakerID: "one", start: 0, end: 3, embedding: invalid)
        #expect(VoiceProfileSelection.select([sample]).isEmpty)
    }
}
