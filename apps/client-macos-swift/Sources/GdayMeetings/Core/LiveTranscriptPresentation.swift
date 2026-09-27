import Foundation

/// Recognition-driven presentation: no clock guesses or per-frame updates.
enum LiveTranscriptPresentation {
    struct Row: Identifiable {
        let phrase: LiveTranscriptPhrase
        let provisional: Bool
        var id: UUID { phrase.id }
    }

    /// Final phrases are cached in timeline order by the view. Merge the small
    /// set of active source partials without re-sorting a long recording.
    static func rows(finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]) -> [Row] {
        let pending = partials.sorted(by: LiveTranscriptPhrase.ordered)
        var result: [Row] = []
        result.reserveCapacity(finalized.count + pending.count)
        var index = 0
        for phrase in finalized {
            while index < pending.count && LiveTranscriptPhrase.ordered(pending[index], phrase) {
                result.append(Row(phrase: pending[index], provisional: true))
                index += 1
            }
            result.append(Row(phrase: phrase, provisional: false))
        }
        result.append(contentsOf: pending[index...].map { Row(phrase: $0, provisional: true) })
        return result
    }

    static func activePhraseID(_ partials: [LiveTranscriptPhrase]) -> UUID? {
        partials.max { left, right in
            left.end == right.end ? LiveTranscriptPhrase.ordered(left, right) : left.end < right.end
        }?.id
    }

    static func newestWordRange(in phrase: LiveTranscriptPhrase) -> Range<String.Index>? {
        let timedWords = phrase.words.filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
        if let word = timedWords.max(by: { $0.end < $1.end }) {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, let matched = phrase.text.range(of: token, options: .backwards) {
                return lastWord(in: phrase.text, range: matched)
                    ?? lastWord(in: phrase.text, range: phrase.text.startIndex..<matched.upperBound)
            }
        }
        return lastWord(in: phrase.text, range: phrase.text.startIndex..<phrase.text.endIndex)
    }

    /// The reference holds its two-word trail until recognition changes or
    /// finalizes. Re-derive from replacement text; never retain stale offsets.
    static func recentWordRanges(in phrase: LiveTranscriptPhrase) -> [Range<String.Index>] {
        guard let newest = newestWordRange(in: phrase) else { return [] }
        if let previous = lastWord(in: phrase.text, range: phrase.text.startIndex..<newest.lowerBound) {
            return [previous, newest]
        }
        return [newest]
    }

    private static func lastWord(in text: String, range: Range<String.Index>) -> Range<String.Index>? {
        var result: Range<String.Index>?
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            result = word
        }
        return result
    }
}
