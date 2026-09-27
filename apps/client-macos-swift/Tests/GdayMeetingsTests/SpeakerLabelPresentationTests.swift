import Testing

@testable import GdayMeetings

struct SpeakerLabelPresentationTests {
    @Test func knownProviderLabelsAreShortenedWithoutChangingOtherLabels() {
        for (raw, expected) in [
            ("mic_SPEAKER_00", "mic_00"), ("mic_SPEAKER_01", "mic_01"),
            ("sys_SPEAKER_123", "sys_123"), ("mic_00", "mic_00"),
            ("SPEAKER_00", "SPEAKER_00"), ("mic_SPEAKER_", "mic_SPEAKER_"),
            ("mic_SPEAKER_00 Alex", "mic_SPEAKER_00 Alex"),
            ("Alex SPEAKER_00", "Alex SPEAKER_00"), ("mic_SPEAKER_一", "mic_SPEAKER_一"),
        ] {
            #expect(SpeakerLabelPresentation.display(raw) == expected)
        }
    }

    @Test func personNamesAndCanonicalLabelsRemainUnchanged() {
        var meeting = Meeting()
        let person = Person(name: "mic_SPEAKER_00")
        let speaker = MeetingSpeaker(
            label: "sys_SPEAKER_01", track: "system", providerName: "RunPod", personID: person.id)
        let segment = TranscriptSegment(start: 0, end: 1, speaker: speaker.label, text: "Hello", speakerID: speaker.id)
        meeting.speakers = [speaker]
        #expect(
            meeting.speakerName(for: segment, people: [person], compactProviderLabel: true)
                == person.name)
        #expect(meeting.speakerName(for: segment, people: [], compactProviderLabel: true) == "sys_01")
        #expect(meeting.speakerName(for: segment, people: []) == "sys_SPEAKER_01")
        #expect(meeting.speakers[0].label == "sys_SPEAKER_01")
        #expect(segment.speaker == "sys_SPEAKER_01")
        #expect(meeting.speakers[0].personID == person.id)
    }
}
