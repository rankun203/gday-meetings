import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptAssociationDisplayTests {
    @Test func previewFixtureSurvivesQueuedAndRepeatedProductionMatching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        _ = await store.addPerson(name: "Person A")
        _ = await store.addPerson(name: "Person B")
        var meeting = Meeting(title: "Synthetic transcript presentation", audioFiles: ["microphone.wav"])
        meeting.duration = 60
        let folder = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic audio revision".utf8).write(to: folder.appendingPathComponent("microphone.wav"))
        try await store.insertImportedMeeting(meeting)
        // Reproduce ordinary Preview's pending suggestion work at fixture entry.
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id])
        try await UIPreview.seedTranscriptAssociationPresentation(store: store, meeting: meeting)
        for _ in 0..<2 {
            await store.refreshVoiceAssignments(meetingIDs: [meeting.id])
            await store.flushVoiceAssignmentRefresh()
            let current = try #require(store.meeting(id: meeting.id))
            let automatic = try #require(current.speakers.first { $0.label == "mic_02" })
            let tentative = try #require(current.speakers.first { $0.label == "mic_03" })
            #expect(automatic.personID != nil && automatic.voiceReviewOrigin?.transcriptAssociationTier == .automatic)
            #expect(tentative.personID != nil && tentative.voiceReviewOrigin?.transcriptAssociationTier == .tentative)
            let uncertain = try #require(current.transcript.first { $0.associationUncertain == true })
            #expect(!uncertain.allowsPersonAssociation(from: automatic))
            #expect(current.transcript.last?.speaker == "mic")
            #expect(current.transcript.last?.sourcePlaceholder == true)
        }
    }

    @Test func reusableChipSeparatesTentativeAutomaticAndAssignedPeople() {
        let person = UUID()
        var row = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Person A", speakerID: UUID(), text: "Synthetic passage.",
            personID: person, transcriptAssociationTier: .tentative)
        let cell = TranscriptNativeCell(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        cell.configure(row, showsSpeakers: true)
        let identityTint = cell.badge.tint
        #expect(cell.speaker.stringValue == "Person A ?")
        #expect(cell.badge.unresolved)
        #expect(cell.speaker.lineBreakMode == .byTruncatingMiddle)
        #expect(cell.speaker.accessibilityLabel() == "Person A")
        #expect(cell.speaker.accessibilityHelp() == "Tentative match. Assign a person to correct it.")
        #expect(cell.badge.toolTip == "Person A. Tentative match. Assign a person to correct it.")
        #expect(row.canAssignPerson)

        row.transcriptAssociationTier = .automatic
        cell.configure(row, showsSpeakers: true)
        #expect(cell.speaker.stringValue == "Person A")
        #expect(!cell.badge.unresolved)
        #expect(cell.badge.tint == identityTint)
        #expect(cell.speaker.lineBreakMode == .byTruncatingTail)
        #expect(cell.speaker.accessibilityHelp() == "Automatically matched. Assign a person to correct it.")

        row.transcriptAssociationTier = nil
        cell.configure(row, showsSpeakers: true)
        #expect(cell.speaker.stringValue == "Person A")
        #expect(!cell.badge.unresolved)
        #expect(cell.speaker.accessibilityHelp() == "Assigned person.")
        #expect(cell.badge.tint == identityTint)

        let source = TranscriptDisplayRow(
            id: UUID(), start: 1, end: 2, speaker: "sys", speakerID: nil, text: "Synthetic source.",
            isSourcePlaceholder: true)
        cell.configure(source, showsSpeakers: true)
        #expect(cell.speaker.stringValue == "sys")
        #expect(cell.speaker.accessibilityHelp() == nil)
        #expect(cell.badge.toolTip == nil)
        #expect(!cell.badge.unresolved)
        #expect(!source.canAssignPerson)
    }

    @Test func tierWithoutAllowedPersonCannotInventTentativeName() {
        let row = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "sys_01", speakerID: UUID(), text: "Unresolved passage.",
            transcriptAssociationTier: .tentative)
        #expect(row.speakerBadgeLabel == "sys_01")
        #expect(!row.hasTentativePerson)
        #expect(row.speakerAssignmentHelp == nil)
    }

    @Test func composedPassageRetainsIdentityTierAndCanonicalTargets() throws {
        let speaker = UUID()
        let person = UUID()
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "sys_01", text: "First.", speakerID: speaker),
            TranscriptSegment(start: 1, end: 2, speaker: "sys_01", text: "Second.", speakerID: speaker),
        ]
        let rows = segments.map {
            TranscriptDisplayRow(
                id: $0.id, start: $0.start, end: $0.end, speaker: "Person A", speakerID: speaker, text: $0.text,
                personID: person, transcriptAssociationTier: .tentative)
        }
        let composed = try #require(TranscriptDisplayRow.passage(rows: rows, segments: segments))
        #expect(composed.speakerBadgeLabel == "Person A ?")
        #expect(composed.transcriptAssociationTier == .tentative)
        #expect(composed.canonicalRows.map(\.id) == segments.map(\.id))
        #expect(composed.sourceRow(atUTF16: composed.text.utf16.count - 1).id == segments[1].id)
    }
}
