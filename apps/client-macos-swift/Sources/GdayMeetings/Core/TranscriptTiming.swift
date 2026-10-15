import Foundation

/// Offsets are UTF-16 in the exact immutable text, never word indices.
struct TranscriptTextRange: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
}

enum TranscriptTimingGranularity: String, Codable, Sendable { case word, run }

struct TranscriptTimedSpan: Codable, Equatable, Sendable {
    var range: TranscriptTextRange
    var start: Double
    var end: Double
    var granularity: TranscriptTimingGranularity
}

struct TranscriptTextTiming: Codable, Equatable, Sendable {
    var text: String
    var spans: [TranscriptTimedSpan]

    var isValid: Bool {
        let value = text as NSString
        var position = 0
        var time = -Double.infinity
        guard !spans.isEmpty else { return false }
        for span in spans {
            let range = NSRange(location: span.range.location, length: span.range.length)
            guard range.location >= position, range.length > 0, range.location <= value.length,
                range.length <= value.length - range.location,
                Range(range, in: text) != nil,
                span.start.isFinite, span.end.isFinite, span.start >= 0, span.end > span.start,
                span.start >= time
            else { return false }
            position = NSMaxRange(range)
            time = span.start
        }
        return true
    }

    func sliced(to range: NSRange) -> Self? {
        guard let stringRange = Range(range, in: text) else { return nil }
        let value = text as NSString
        let selected = spans.compactMap { span -> TranscriptTimedSpan? in
            let original = NSRange(location: span.range.location, length: span.range.length)
            let overlap = NSIntersectionRange(original, range)
            guard overlap.length > 0 else { return nil }
            // Fragment text trims surrounding whitespace. Retain the native interval
            // when only decoration was trimmed, never when lexical text was cut.
            let before = value.substring(
                with: NSRange(location: original.location, length: overlap.location - original.location))
            let after = value.substring(
                with: NSRange(location: NSMaxRange(overlap), length: NSMaxRange(original) - NSMaxRange(overlap)))
            guard (before + after).allSatisfy(\.isWhitespace) else { return nil }
            var result = span
            result.range = .init(location: overlap.location - range.location, length: overlap.length)
            return result
        }
        let result = Self(text: String(text[stringRange]), spans: selected)
        return result.isValid ? result : nil
    }

    static func fromWords(
        text: String, words: [LiveTranscriptWord], granularity: TranscriptTimingGranularity = .run
    ) -> Self? {
        let value = text as NSString
        var cursor = 0
        var spans: [TranscriptTimedSpan] = []
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let range = value.range(
                of: token, options: [], range: NSRange(location: cursor, length: value.length - cursor))
            guard range.location != NSNotFound else { return nil }
            spans.append(
                .init(
                    range: .init(location: range.location, length: range.length),
                    start: word.start, end: word.end, granularity: granularity))
            cursor = NSMaxRange(range)
        }
        let result = Self(text: text, spans: spans)
        return result.isValid ? result : nil
    }
}

/// Each rendered passage retains exact source spans across regrouping.
struct TranscriptSourceSpan: Codable, Equatable, Sendable {
    var rowID: UUID
    var range: TranscriptTextRange
    var text: String
    var separatorBefore: String? = nil
}

extension LiveTranscriptPhrase {
    var validTextTiming: TranscriptTextTiming? {
        if let textTiming {
            return textTiming.text == text && textTiming.isValid ? textTiming : nil
        }
        return TranscriptTextTiming.fromWords(text: text, words: words)
    }
}
