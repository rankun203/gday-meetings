import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingSpeakerPanelTests {
    @Test func assignmentListIncludesDetectedLabelsWithoutRecognitionEvidence() {
        let detected = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", independentTurnAttribution: true)
        let imported = MeetingSpeaker(label: "Guest", track: "", providerName: "Imported Transcript")
        let placeholder = MeetingSpeaker(
            label: "mic", track: "microphone", providerName: "Synthetic", sourcePlaceholder: .microphone)
        var attendance = MeetingSpeaker(label: "Reviewed Voice", track: "system", providerName: "Voice Review")
        attendance.voiceReviewOrigin = .init(speakerID: UUID(), evidenceOnly: true)
        var meeting = Meeting()
        meeting.speakers = [detected, imported, placeholder, attendance]

        #expect(meeting.assignableSpeakers.map(\.id) == [detected.id, imported.id])
        #expect(!detected.canReviewVoice)
        #expect(!imported.canReviewVoice)
    }

    @Test func turnProjectionsKeepTheirCanonicalLabelAndExplicitPassagesKeepTheirOwnScope() {
        let canonical = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", independentTurnAttribution: true)
        var first = canonical
        first.id = UUID()
        first.personID = UUID()
        first.voiceReviewOrigin = .init(speakerID: canonical.id, transcriptAssociationTier: .automatic)
        var second = first
        second.id = UUID()
        second.personID = UUID()
        var corrected = canonical
        corrected.id = UUID()
        corrected.passageAssignmentOrigin = .init(speakerID: canonical.id, speaker: canonical.label)
        var meeting = Meeting()
        meeting.speakers = [canonical, first, second, corrected]
        meeting.transcript = [
            .init(start: 0, end: 1, text: "First turn", speakerID: first.id),
            .init(start: 2, end: 3, text: "Second turn", speakerID: second.id),
        ]

        #expect(meeting.speakerLabelAssignments[canonical.id]?.variesByPassage == true)
        #expect(meeting.speakerLabelAssignments[corrected.id] == nil)
        #expect(meeting.speakerLabelAssignments[canonical.id]?.hasAssignments == true)
        meeting.speakers[2].personID = first.personID
        meeting.speakers[2].voiceReviewOrigin?.transcriptAssociationTier = .tentative
        #expect(meeting.speakerLabelAssignments[canonical.id]?.uniformPersonID == first.personID)
        #expect(meeting.speakerLabelAssignments[canonical.id]?.hasTentativePerson == true)
        meeting.speakers[2].personID = nil
        #expect(meeting.speakerLabelAssignments[canonical.id]?.variesByPassage == true)
        #expect(meeting.assignableSpeakers.map(\.id) == [canonical.id, corrected.id])
        meeting.speakers[1].personID = nil
        #expect(meeting.speakerLabelAssignments[canonical.id]?.hasAssignments == false)
        #expect(meeting.speakerLabelAssignments[canonical.id]?.uniformPersonID == nil)
        meeting.speakers.removeFirst()
        #expect(meeting.assignableSpeakers.map(\.id) == [first.id, second.id, corrected.id])
    }

    @Test func assigningUnbackedLabelPreservesOtherLabelsAndCorrectedPassages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let originalPerson = await store.addPerson(name: "Person A")
        let replacementPerson = await store.addPerson(name: "Person B")
        let label = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", independentTurnAttribution: true)
        let other = MeetingSpeaker(
            label: "sys_02", track: "system", providerName: "Synthetic", personID: originalPerson,
            manuallyAssigned: true, independentTurnAttribution: true)
        var meeting = Meeting(title: "Synthetic speaker assignments")
        meeting.speakers = [label, other]
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: label.label, text: "First passage", speakerID: label.id, source: .system),
            .init(
                start: 3, end: 5, speaker: label.label, text: "Corrected passage", speakerID: label.id, source: .system),
            .init(start: 6, end: 8, speaker: other.label, text: "Other label", speakerID: other.id, source: .system),
        ]
        meeting = try #require(
            TranscriptPassageAssignment.applying(
                to: meeting, rowID: meeting.transcript[1].id, personID: originalPerson,
                people: [originalPerson, replacementPerson]))
        let correctedID = try #require(meeting.transcript[1].speakerID)
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        store.voiceLibrary.didChange = nil
        store.voiceLibrary.didChangeProjection = nil

        #expect(await store.assignSpeaker(meetingID: meeting.id, speakerID: label.id, personID: replacementPerson))
        await store.voicePreparation.awaitReferenceSelections()
        let assigned = try #require(store.meeting(id: meeting.id))
        #expect(assigned.speakers.first { $0.id == label.id }?.personID == replacementPerson)
        #expect(assigned.speakers.first { $0.id == other.id }?.personID == originalPerson)
        #expect(assigned.speakers.first { $0.id == correctedID }?.personID == originalPerson)
        #expect(assigned.transcript.map(\.speakerID) == meeting.transcript.map(\.speakerID))
        #expect(assigned.assignableSpeakers.map(\.id) == [label.id, other.id, correctedID])
        #expect(assigned.speakers.first { $0.id == label.id }?.canReviewVoice == false)

        #expect(await store.assignSpeaker(meetingID: meeting.id, speakerID: label.id, personID: nil))
        let cleared = try #require(store.meeting(id: meeting.id))
        #expect(cleared.speakers.first { $0.id == label.id }?.personID == nil)
        #expect(cleared.speakers.first { $0.id == other.id }?.personID == originalPerson)
        #expect(cleared.speakers.first { $0.id == correctedID }?.personID == originalPerson)
        #expect(cleared.speakerLabelAssignments[label.id]?.hasAssignments == false)
    }
}
