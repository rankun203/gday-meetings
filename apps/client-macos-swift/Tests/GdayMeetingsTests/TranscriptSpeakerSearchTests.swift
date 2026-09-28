import Foundation
import Testing

@testable import GdayMeetings

struct TranscriptSpeakerSearchTests {
    @Test func autocompleteFindsCaseAndAccentVariantsAndLimitsResults() {
        let people = [Person(name: "Zoë Adams"), Person(name: "Alex Morgan"), Person(name: "Sam Chen")]
        #expect(TranscriptSpeakerSearch.matches(people, query: " zoe ").map(\.name) == ["Zoë Adams"])
        #expect(TranscriptSpeakerSearch.matches(people, query: "MORGAN").map(\.name) == ["Alex Morgan"])
        #expect(
            TranscriptSpeakerSearch.matches(people, query: "", limit: 2).map(\.name) == ["Alex Morgan", "Sam Chen"])
        #expect(TranscriptSpeakerSearch.matches(people, query: "missing").isEmpty)
    }

    @Test func speakerIdentityWinsOverLabelsAndAmbiguousLabelsAreNotAssigned() {
        let first = MeetingSpeaker(label: "SPEAKER_00", track: "system", providerName: "Provider")
        let second = MeetingSpeaker(label: "SPEAKER_00", track: "microphone", providerName: "Provider")
        let segment = TranscriptSegment(speaker: first.label, speakerID: second.id)
        #expect(TranscriptSpeakerSearch.speaker(for: segment, in: [first, second])?.id == second.id)
        let ambiguous = TranscriptSegment(speaker: first.label)
        #expect(TranscriptSpeakerSearch.speaker(for: ambiguous, in: [first, second]) == nil)
        #expect(TranscriptSpeakerSearch.speaker(for: ambiguous, in: [first])?.id == first.id)
    }
}
