import Foundation
import Testing

@testable import GdayMeetings

struct VoiceExampleNavigationTests {
    @Test func legacyAssignmentOpensFirstChronologicalPassageForThatSpeaker() {
        var meeting = Meeting(title: "Saved conversation")
        let speaker = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic Provider")
        let other = MeetingSpeaker(label: "sys_02", track: "system", providerName: "Synthetic Provider")
        let first = TranscriptSegment(
            start: 10, end: 14, speaker: speaker.label, text: "Earlier passage.", speakerID: speaker.id)
        meeting.speakers = [speaker, other]
        meeting.transcript = [
            .init(start: 30, end: 34, speaker: speaker.label, text: "Later passage.", speakerID: speaker.id),
            .init(start: 0, end: 4, speaker: other.label, text: "Another voice.", speakerID: other.id),
            first,
        ]
        let example = VoiceExample(meetingID: meeting.id, speakerID: speaker.id, source: "unknown")
        #expect(VoiceExampleTranscriptNavigation.rowID(for: example, meeting: meeting) == first.id)
    }

    @Test func discoveredExcerptUsesItsAudioSourceWhenTimesOverlap() {
        var meeting = Meeting(title: "Two audio sources")
        meeting.audioFiles = ["microphone.wav", "system.wav"]
        let microphone = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic Provider")
        let system = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic Provider")
        let expected = TranscriptSegment(
            start: 10, end: 15, speaker: system.label, text: "System passage.", speakerID: system.id)
        meeting.speakers = [microphone, system]
        meeting.transcript = [
            .init(start: 10, end: 15, speaker: microphone.label, text: "Microphone passage.", speakerID: microphone.id),
            expected,
        ]
        let example = VoiceExample(
            meetingID: meeting.id, speakerID: UUID(), source: "system", audioFile: "system.wav", start: 11, end: 14)
        #expect(VoiceExampleTranscriptNavigation.rowID(for: example, meeting: meeting) == expected.id)
    }

    @Test func projectedSpeakerRetainsItsOriginalNavigationIdentity() {
        var meeting = Meeting(title: "Reviewed conversation")
        let originalID = UUID()
        var projected = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic Provider")
        projected.voiceReviewOrigin = .init(
            speakerID: originalID, personID: nil, manuallyAssigned: false, confidence: nil)
        meeting.speakers = [projected]
        let row = TranscriptSegment(
            start: 12, end: 18, speaker: projected.label, text: "Reviewed passage.", speakerID: projected.id)
        meeting.transcript = [row]
        let example = VoiceExample(meetingID: meeting.id, speakerID: originalID, source: "unknown")
        #expect(VoiceExampleTranscriptNavigation.rowID(for: example, meeting: meeting) == row.id)
    }
}
