import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptPresentationTests {
    private func phrase(_ text: String, start: Double = 0, end: Double = 2) -> LiveTranscriptPhrase {
        .init(session: UUID(), source: .microphone, start: start, end: end, text: text)
    }
    @Test func timingSelectsLatestWordAndPreservesOriginalText() {
        var value = phrase("Go, go!  Done.\n")
        value.words = [.init(text: "go", start: 1, end: 1.5), .init(text: "Go", start: 0, end: 0.5)]
        let range = LiveTranscriptPresentation.newestWordRange(in: value)!
        #expect(String(value.text[range]) == "go")
        #expect(String(value.text[..<range.lowerBound]) == "Go, ")
        #expect(String(value.text[range.upperBound...]) == "!  Done.\n")
    }
    @Test func unicodeFallbackDoesNotChangeWhitespaceOrEmoji() {
        let value = phrase("🙂  We’ll update café…  \n")
        let range = LiveTranscriptPresentation.newestWordRange(in: value)!
        #expect(String(value.text[range]) == "café")
        #expect(String(value.text[..<range.lowerBound]) == "🙂  We’ll update ")
        #expect(String(value.text[range.upperBound...]) == "…  \n")
        #expect(LiveTranscriptPresentation.newestWordRange(in: phrase("  … \n")) == nil)
    }
    @Test func chineseTimedSpanUsesExactOriginalText() {
        var value = phrase("我们明天开会。")
        value.words = [.init(text: "开会", start: 1, end: 2)]
        let range = LiveTranscriptPresentation.newestWordRange(in: value)!
        #expect(String(value.text[range]) == "开会")
        #expect(String(value.text[..<range.lowerBound]) == "我们明天")
        #expect(String(value.text[range.upperBound...]) == "。")
    }
    @Test func mergesSourcesInTimelineOrder() {
        let final = phrase("Settled", start: 10, end: 12)
        let partial = phrase("Earlier unfinished", start: 5, end: 13)
        let later = phrase("Newest", start: 15, end: 16)
        let rows = LiveTranscriptPresentation.rows(finalized: [final], partials: [later, partial])
        #expect(rows.map(\.phrase.start) == [5, 10, 15])
        #expect(rows.map(\.provisional) == [true, false, true])
        #expect(LiveTranscriptPresentation.activePhraseID([partial, later]) == later.id)
    }
    @Test func correctedDraftReplacesPriorTextAndFinalSettles() {
        let first = phrase("We will meat tomorrow")
        var corrected = first
        corrected.text = "We will meet tomorrow."
        var other = phrase("Other track", start: 3, end: 4)
        other.source = .system
        var partials = LiveTranscriptPhrase.replacingPartials([], with: first, final: false)
        partials = LiveTranscriptPhrase.replacingPartials(partials, with: other, final: false)
        partials = LiveTranscriptPhrase.replacingPartials(partials, with: corrected, final: false)
        #expect(partials.count == 2)
        #expect(partials.contains { $0.text == corrected.text })
        #expect(!partials.contains { $0.text == first.text })
        partials = LiveTranscriptPhrase.replacingPartials(partials, with: corrected, final: true)
        #expect(partials == [other])
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en-US")
        draft.accept(corrected)
        let rows = LiveTranscriptPresentation.rows(finalized: draft.phrases, partials: partials)
        #expect(rows.first?.provisional == false)
        #expect(rows.first?.phrase.text == corrected.text)
        #expect(LiveTranscriptPresentation.activePhraseID(partials) == other.id)
    }
}
