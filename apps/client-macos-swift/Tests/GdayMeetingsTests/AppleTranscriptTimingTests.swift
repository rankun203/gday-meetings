import CoreMedia
import Foundation
import Speech
import Testing

@testable import GdayMeetings

struct AppleTranscriptTimingTests {
    private func run(_ text: String, _ start: Double? = nil, _ end: Double? = nil) -> AttributedString {
        var result = AttributedString(text)
        if let start, let end {
            result.audioTimeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
        }
        return result
    }

    @Test func nativeOffsetsSurviveUntimedRepeatedWordsEmojiAndPunctuation() throws {
        let input =
            run("go ") + run("go", 1, 2) + run("。", 2, 2)
            + run("🙂 ") + run("世界", 3, 4)
        let extracted = AppleTranscriptTiming.extract(input)
        let timing = try #require(extracted.timing)
        #expect(timing.text == "go go。🙂 世界")
        #expect(timing.spans.map(\.range.location) == [3, 9])
        #expect(timing.spans.map(\.granularity) == [.word, .word])
        #expect(extracted.words.map(\.text) == ["go", "世界"])
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 4,
            text: extracted.text, words: extracted.words, textTiming: timing)
        let restored = try JSONDecoder().decode(LiveTranscriptPhrase.self, from: JSONEncoder().encode(phrase))
        let row = TranscriptSegment(live: restored)
        #expect(row.timing == timing)
        #expect(TranscriptSegment(live: row.livePhrase(meetingID: UUID())).timing == timing)
        let persisted = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(row))
        #expect(persisted.timing == timing)
    }

    @Test func paragraphMergeRetainsNativeOffsetsAndCoarseRuns() throws {
        let session = UUID()
        func phrase(_ value: AttributedString, start: Double, end: Double) -> LiveTranscriptPhrase {
            let value = AppleTranscriptTiming.extract(value)
            return .init(
                session: session, source: .system, start: start, end: end,
                text: value.text, words: value.words, textTiming: value.timing)
        }
        let first = phrase(run("first phrase", 0, 1), start: 0, end: 1)
        let second = phrase(run("untimed ") + run("second", 1.2, 2), start: 1.1, end: 2)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en-US")
        draft.accept(first)
        draft.accept(second)
        let row = try #require(draft.segments.first)
        #expect(draft.segments.count == 1)
        #expect(row.text == "first phrase untimed second")
        #expect(row.timing?.spans.map(\.range.location) == [0, 21])
        #expect(row.timing?.spans.map(\.granularity) == [.run, .word])
        #expect(row.timing?.isValid == true)
    }

    @Test func changedTextDoesNotReuseNativeAlignment() {
        let value = AppleTranscriptTiming.extract(run("Original", 0, 1))
        var phrase = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 1,
            text: value.text, words: value.words, textTiming: value.timing)
        phrase.text = "Edited"
        phrase.words = []
        #expect(TranscriptSegment(live: phrase).timing == nil)
    }

    @Test func liveSlicesPreserveNativeGranularityAndRebaseOffsets() throws {
        let value = AppleTranscriptTiming.extract(run("Hello", 0, 1) + run(" world!", 1, 2))
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 2,
            text: value.text, words: value.words, textTiming: value.timing)
        let fragment = try #require(phrase.fragment(start: 1, end: 2))
        #expect(fragment.text == "world!")
        #expect(fragment.textTiming?.spans.first?.range.location == 0)
        #expect(fragment.textTiming?.spans.first?.granularity == .word)
        #expect(TranscriptSegment(live: fragment).timing == fragment.textTiming)
        let suffix = try #require(phrase.after(1))
        #expect(suffix.textTiming == fragment.textTiming)
    }

    @Test func staleExplicitOffsetsCannotFallBackToRepeatedWordSearch() {
        let value = AppleTranscriptTiming.extract(run("go ") + run("go", 1, 2))
        var phrase = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 2,
            text: value.text, words: value.words, textTiming: value.timing)
        phrase.text = "go"
        #expect(TranscriptSegment(live: phrase).timing == nil)
        let coarse = AppleTranscriptTiming.extract(run("two words", 0, 1))
        #expect(coarse.timing?.sliced(to: NSRange(location: 4, length: 5)) == nil)
    }
}
