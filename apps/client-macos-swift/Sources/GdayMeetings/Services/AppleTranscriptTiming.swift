import CoreMedia
import Foundation
import NaturalLanguage
import Speech

/// Preserve Speech's actual timed runs. A run may contain more than one word;
/// splitting it into lexical words would invent alignment the provider did not give us.
enum AppleTranscriptTiming {
    struct Extracted {
        var text: String
        var words: [LiveTranscriptWord]
        var timing: TranscriptTextTiming?
    }

    static func extract(_ attributed: AttributedString) -> Extracted {
        let text = String(attributed.characters)
        var offset = 0
        var lastStart = -Double.infinity
        var spans: [TranscriptTimedSpan] = []
        var words: [LiveTranscriptWord] = []
        for run in attributed.runs {
            let value = String(attributed[run.range].characters)
            let length = value.utf16.count
            defer { offset += length }
            guard let time = run.audioTimeRange else { continue }
            let start = time.start.seconds
            let end = CMTimeRangeGetEnd(time).seconds
            // Untimed/invalid runs keep their text and offsets but must not erase
            // the valid alignment of surrounding speech (for example punctuation).
            guard length > 0, start.isFinite, end.isFinite, start >= 0,
                end > start, start >= lastStart,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            spans.append(
                .init(
                    range: .init(location: offset, length: length), start: start, end: end,
                    granularity: granularity(of: value)))
            words.append(.init(text: value, start: start, end: end))
            lastStart = start
        }
        let timing = TranscriptTextTiming(text: text, spans: spans)
        return .init(text: text, words: words, timing: timing.isValid ? timing : nil)
    }

    /// Classify an existing native interval; never divide its time range.
    private static func granularity(of text: String) -> TranscriptTimingGranularity {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard tokens.count == 1, let token = tokens.first else { return .run }
        let decoration = String(text[..<token.lowerBound]) + String(text[token.upperBound...])
        return decoration.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
        } ? .word : .run
    }
}
