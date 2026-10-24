import Foundation
import Testing

@testable import GdayMeetings

struct TranscriptSpeakerAssignmentPresentationTests {
    private func row(
        personID: UUID? = UUID(), tier: VoiceTranscriptAssociation.Tier? = nil,
        isSourcePlaceholder: Bool = false
    ) -> TranscriptDisplayRow {
        TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Person A", speakerID: UUID(), text: "Synthetic passage.",
            personID: personID, isSourcePlaceholder: isSourcePlaceholder, transcriptAssociationTier: tier)
    }

    @Test func headerUsesRecordingLabelInsteadOfAssignedName() {
        let speaker = MeetingSpeaker(label: "sys_SPEAKER_01", track: "system", providerName: "Provider")
        #expect(TranscriptSpeakerAssignmentExplanation.title(for: speaker) == "Assign Person · sys_01")
        let unlabeled = MeetingSpeaker(label: "", track: "system", providerName: "Provider")
        #expect(TranscriptSpeakerAssignmentExplanation.title(for: unlabeled) == "Assign Person · Unlabeled")
    }

    @Test func unassignedAndTentativeIdentityHaveDistinctExplanations() {
        let unassigned = TranscriptSpeakerAssignmentExplanation(displayedRow: row(personID: nil, tier: .tentative))
        #expect(unassigned.dottedReasons == [.noAssignedPerson])
        #expect(!unassigned.automaticallyMatched)
        let tentative = TranscriptSpeakerAssignmentExplanation(displayedRow: row(tier: .tentative))
        #expect(tentative.dottedReasons == [.tentativePerson])
        #expect(!tentative.automaticallyMatched)
    }

    @Test func solidAutomaticAndExplicitAssignmentsDoNotInventManualConfirmation() {
        let automatic = TranscriptSpeakerAssignmentExplanation(displayedRow: row(tier: .automatic))
        #expect(automatic.dottedReasons.isEmpty)
        #expect(automatic.automaticallyMatched)
        let assigned = TranscriptSpeakerAssignmentExplanation(displayedRow: row())
        #expect(assigned.dottedReasons.isEmpty)
        #expect(!assigned.automaticallyMatched)
    }

    @Test func composedBadgeRetainsSimultaneousReasonsAndNonfirstTarget() throws {
        let unlabelled = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "sys", speakerID: nil, text: "First.")
        var identified = row(tier: .tentative)
        let segments = [
            TranscriptSegment(id: unlabelled.id, start: 0, end: 1, speaker: "sys", text: "First."),
            TranscriptSegment(
                id: identified.id, start: 1, end: 2, speaker: "sys_01", text: "Second.",
                speakerID: identified.speakerID),
        ]
        let passage = try #require(TranscriptDisplayRow.passage(rows: [unlabelled, identified], segments: segments))
        let context = TranscriptSpeakerPickerContext(displayedRow: passage)
        #expect(context.rowID == identified.id)
        #expect(context.rowID != passage.id)
        #expect(context.explanation.dottedReasons == [.tentativePerson, .wordsWithoutSpeaker])
        #expect(TranscriptSpeakerAssignmentExplanation.hasDottedOutline(for: passage))
        // Expansion produces a solidly attributed constituent; the captured context
        // must continue explaining the original composed badge.
        identified.transcriptAssociationTier = nil
        #expect(!TranscriptSpeakerAssignmentExplanation(displayedRow: identified).hasDottedOutline)
        #expect(context.explanation.hasDottedOutline)
    }

    @Test func wordsWithoutPersonAndUnassignedPassageCanBothBeExplained() {
        var passage = row(personID: nil)
        passage.hasUnattributedWords = true
        passage.constituents = [row(personID: nil), row(personID: nil)]
        let explanation = TranscriptSpeakerAssignmentExplanation(displayedRow: passage)
        #expect(explanation.dottedReasons == [.noAssignedPerson, .wordsWithoutPerson])
        #expect(explanation.hasDottedOutline == TranscriptSpeakerAssignmentExplanation.hasDottedOutline(for: passage))
    }

    @Test func sourcePlaceholderNeverGetsPersonAssignmentExplanation() {
        var source = row(personID: nil, isSourcePlaceholder: true)
        source.hasUnattributedWords = true
        let explanation = TranscriptSpeakerAssignmentExplanation(displayedRow: source)
        #expect(explanation.dottedReasons.isEmpty)
        #expect(!explanation.automaticallyMatched)
        #expect(!TranscriptSpeakerAssignmentExplanation.hasDottedOutline(for: source))
    }
}
