import Foundation
import Testing

@testable import GdayMeetings

struct MeetingSpeakerColorsTests {
    @Test func persistedSlotsSurviveReorderingRenamingAndNewSpeakers() throws {
        var meeting = Meeting(title: "Synthetic recording")
        meeting.speakers = (0..<12).map { index in
            MeetingSpeaker(label: "voice_\(index)", track: "system", providerName: "Synthetic", personID: UUID())
        }
        let assigned = MeetingSpeakerColors.assigning(meeting)
        let reopened = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(assigned))
        let original = MeetingSpeakerColors.slots(for: reopened.speakers)
        #expect(Set(original.values).count == 12)
        var edited = reopened
        edited.speakers.reverse()
        edited.speakers[0].personID = UUID()
        edited.speakers[0].label = "Renamed speaker"
        edited.speakers.insert(
            MeetingSpeaker(label: "New voice", track: "microphone", providerName: "Synthetic"), at: 0)
        let updated = MeetingSpeakerColors.assigning(edited, previous: reopened)
        let result = MeetingSpeakerColors.slots(for: updated.speakers)
        for (id, slot) in original { #expect(result[id] == slot) }
        #expect(Set(result.values).count == 13)
        let savedAgain = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(updated))
        #expect(MeetingSpeakerColors.slots(for: savedAgain.speakers) == result)
    }

    @Test func legacyAllocationPrecedesInsertionAndProjectionKeepsSourceColor() {
        var previous = Meeting(title: "Synthetic recording")
        previous.speakers = [
            MeetingSpeaker(label: "First", track: "system", providerName: "Synthetic"),
            MeetingSpeaker(label: "Second", track: "system", providerName: "Synthetic"),
        ]
        let fallback = MeetingSpeakerColors.slots(for: previous.speakers)
        var edited = previous
        var projected = previous.speakers[0]
        projected.id = UUID()
        projected.voiceReviewOrigin = .init(speakerID: previous.speakers[0].id)
        projected.personID = UUID()
        edited.speakers.removeFirst()
        edited.speakers.append(projected)
        var sameVoice = projected
        sameVoice.id = UUID()
        edited.speakers.append(sameVoice)
        var differentVoice = projected
        differentVoice.id = UUID()
        differentVoice.personID = UUID()
        edited.speakers.append(differentVoice)
        edited.speakers.insert(MeetingSpeaker(label: "New", track: "system", providerName: "Synthetic"), at: 0)
        let saved = MeetingSpeakerColors.assigning(edited, previous: previous)
        let slots = MeetingSpeakerColors.slots(for: saved.speakers)
        #expect(slots[previous.speakers[1].id] == fallback[previous.speakers[1].id])
        let firstSlot = slots[MeetingSpeakerColors.identity(projected)]
        let secondSlot = slots[MeetingSpeakerColors.identity(differentVoice)]
        #expect(firstSlot != secondSlot)
        #expect(slots[MeetingSpeakerColors.identity(sameVoice)] == firstSlot)
        #expect([firstSlot, secondSlot].contains(fallback[previous.speakers[0].id]))
        let reopenedSlots = MeetingSpeakerColors.slots(for: saved.speakers)
        #expect(reopenedSlots == slots)
    }
}
