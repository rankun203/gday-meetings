import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct LiveTranscriptParagraphTests {
    private let session = UUID()
    private let identity = UUID()
    private func phrase(_ text: String, _ start: Double, _ end: Double) -> LiveTranscriptPhrase {
        var value = LiveTranscriptPhrase(session: session, source: .system, start: start, end: end, text: text)
        value.speakerIdentity = identity
        value.diarizationLabel = "sys_02"
        return value
    }

    @Test func joinsOneSentenceAndAdoptsTheSameParagraphWithoutChangingRawPhrases() {
        let first = phrase("We can", 0, 1)
        let second = phrase("review the draft.", 1.2, 3)
        let third = phrase("Another sentence.", 3, 5)
        let groups = LiveTranscriptParagraphs.groups(finalized: [first, second, third], partials: [])
        #expect(groups.map(\.phrase.text) == ["We can review the draft.", "Another sentence."])
        #expect(groups[0].phrase.id == first.id)
        #expect(groups[0].phrase.end == second.end)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.phrases = [first, second, third]
        #expect(draft.segments.map(\.text) == groups.map(\.phrase.text))
        #expect(draft.phrases.count == 3)
    }

    @Test func respectsSpeakerSourceSessionPauseOverlapAndManualBoundaries() {
        let first = phrase("Opening words", 0, 1)
        var next = phrase("continuation", 1.1, 2)
        func count(_ value: LiveTranscriptPhrase) -> Int {
            LiveTranscriptParagraphs.groups(finalized: [first, value], partials: []).count
        }
        #expect(count(next) == 1)
        next.speakerIdentity = UUID()
        #expect(count(next) == 2)
        next = phrase("unknown voice", 1.1, 2)
        next.speakerIdentity = nil
        next.diarizationLabel = "sys_?"
        #expect(count(next) == 2)
        next = phrase("another assigned person", 1.1, 2)
        next.personID = UUID()
        #expect(count(next) == 2)
        next = phrase("continuation", 1.1, 2)
        next.source = .microphone
        #expect(count(next) == 2)
        next = phrase("continuation", 1.1, 2)
        next.session = UUID()
        #expect(count(next) == 2)
        #expect(count(phrase("after pause", 2, 3)) == 2)
        #expect(count(phrase("overlap", 0.5, 2)) == 2)
        #expect(count(phrase("long passage", 1.1, 31)) == 2)
        next = phrase("continuation", 1.1, 2)
        next.userEdited = true
        #expect(count(next) == 2)
        let change = LiveTranscriptOverride(anchor: first, personID: UUID(), personWasAssigned: true)
        #expect(
            LiveTranscriptParagraphs.groups(
                finalized: [first, phrase("next", 1.1, 2)], partials: [], overrides: [change]
            ).count == 2)
    }

    @Test func joinsChineseWithoutInsertedSpacesAndStopsAtSentenceEnd() {
        let groups = LiveTranscriptParagraphs.groups(
            finalized: [phrase("我们可以", 0, 1), phrase("检查示例。", 1, 2), phrase("下一句。", 2, 3)], partials: [])
        #expect(groups.map(\.phrase.text) == ["我们可以检查示例。", "下一句。"])
    }

    @Test func partialUnderlineAndRedTrailStayInsidePartialSubstring() throws {
        let first = phrase("We can", 0, 1)
        let pending = phrase("review now", 1, 2)
        let snapshot = LiveTranscriptDisplay.snapshot(finalized: [first], partials: [pending], people: [])
        let row = try #require(snapshot.rows.first)
        #expect(snapshot.rows.count == 1)
        #expect(row.text == "We can review now")
        #expect(row.provisionalTextRanges == [NSRange(location: 7, length: 10)])
        #expect(row.recentWordRanges == [NSRange(location: 7, length: 6), NSRange(location: 14, length: 3)])
        let cell = TranscriptNativeCell()
        cell.configure(row, showsSpeakers: true)
        #expect(cell.body.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect(cell.body.attributedStringValue.attribute(.underlineStyle, at: 7, effectiveRange: nil) != nil)
        #expect(cell.body.attributedStringValue.attribute(.underlineStyle, at: 16, effectiveRange: nil) != nil)
        #expect(cell.body.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(snapshot.phrases[row.id]?.end == pending.end)
        let finalized = LiveTranscriptDisplay.rows(finalized: [first, pending], partials: [], people: [])
        #expect(finalized.count == 1)
        #expect(finalized[0].provisionalTextRanges?.isEmpty == true)
        #expect(finalized[0].recentWordRanges.isEmpty)
        #expect(!finalized[0].isProvisional)
    }

    @Test func capturedParagraphEditAndAssignmentDoNotConsumeLaterWords() throws {
        let first = phrase("We can", 0, 1)
        var pending = phrase("review now", 1, 2)
        pending.words = [.init(text: "review", start: 1, end: 1.5), .init(text: "now", start: 1.5, end: 2)]
        let anchor = try #require(
            LiveTranscriptParagraphs.groups(finalized: [first], partials: [pending]).first?.phrase)
        var extended = pending
        extended.end = 3
        extended.text = "review now together"
        extended.words.append(.init(text: "together", start: 2, end: 3))
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.phrases = [first, extended]
        draft.updateText("Manual correction", for: anchor)
        let rows = draft.resolvedRows().finalized
        #expect(rows.contains { $0.text == "Manual correction" && $0.end == 2 })
        #expect(rows.contains { $0.text == "together" && $0.start == 2 })
        var attributed = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        attributed.phrases = [first, extended]
        let person = UUID()
        attributed.assignPerson(person, for: anchor)
        let assigned = attributed.resolvedRows().finalized
        #expect(assigned.contains { $0.personID == person && $0.end == 2 })
        #expect(assigned.contains { $0.text == "together" && $0.personID == nil })
    }
}
