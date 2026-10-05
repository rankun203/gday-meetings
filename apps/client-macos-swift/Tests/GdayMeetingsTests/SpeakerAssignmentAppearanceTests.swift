import AppKit
import Testing

@testable import GdayMeetings

struct SpeakerAssignmentAppearanceTests {
    @Test func assignedMenusUseTranscriptSlotsAndUnassignedRemainsNeutral() {
        var assigned = MeetingSpeaker(label: "First", track: "system", providerName: "Synthetic", personID: UUID())
        assigned.colorSlot = 5
        let unassigned = MeetingSpeaker(label: "Second", track: "microphone", providerName: "Synthetic")
        var projected = assigned
        projected.id = UUID()
        projected.voiceReviewOrigin = .init(speakerID: assigned.id)
        projected.colorSlot = 2
        let speakers = [assigned, unassigned, projected]
        let slots = MeetingSpeakerColors.slots(for: speakers)
        #expect(TranscriptSpeakerPalette.assignmentTint(for: unassigned, slots: slots) == nil)
        for speaker in [assigned, projected] {
            let identity = MeetingSpeakerColors.identity(speaker)
            #expect(
                TranscriptSpeakerPalette.assignmentTint(for: speaker, slots: slots)
                    == TranscriptSpeakerPalette.color(for: identity.uuidString, index: slots[identity]))
        }
        #expect(
            TranscriptSpeakerPalette.assignmentTint(for: assigned, slots: slots)
                != TranscriptSpeakerPalette.assignmentTint(for: projected, slots: slots))
        var renamed = assigned
        renamed.label = "Renamed"
        #expect(
            TranscriptSpeakerPalette.assignmentTint(for: renamed, slots: slots)
                == TranscriptSpeakerPalette.assignmentTint(for: assigned, slots: slots))
    }
}
