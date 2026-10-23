import AppKit
import Testing

@testable import GdayMeetings

struct SpeakerAssignmentAppearanceTests {
    @Test func assignedMenusFollowPersonAcrossMeetingsAndUnassignedRemainsNeutral() {
        var assigned = MeetingSpeaker(label: "First", track: "system", providerName: "Synthetic", personID: UUID())
        assigned.colorSlot = 5
        let unassigned = MeetingSpeaker(label: "Second", track: "microphone", providerName: "Synthetic")
        var projected = assigned
        projected.id = UUID()
        projected.voiceReviewOrigin = .init(speakerID: assigned.id)
        projected.colorSlot = 2
        #expect(TranscriptSpeakerPalette.assignmentTint(for: unassigned) == nil)
        for speaker in [assigned, projected] {
            #expect(
                TranscriptSpeakerPalette.assignmentTint(for: speaker)
                    == TranscriptSpeakerPalette.color(for: speaker.personID!.uuidString))
        }
        #expect(
            TranscriptSpeakerPalette.assignmentTint(for: assigned)
                == TranscriptSpeakerPalette.assignmentTint(for: projected))
        var anotherMeeting = assigned
        anotherMeeting.id = UUID()
        anotherMeeting.colorSlot = 7
        #expect(
            TranscriptSpeakerPalette.assignmentTint(for: anotherMeeting)
                == TranscriptSpeakerPalette.assignmentTint(for: assigned))
        var renamed = assigned
        renamed.label = "Renamed"
        #expect(
            TranscriptSpeakerPalette.assignmentTint(for: renamed)
                == TranscriptSpeakerPalette.assignmentTint(for: assigned))
    }
}
