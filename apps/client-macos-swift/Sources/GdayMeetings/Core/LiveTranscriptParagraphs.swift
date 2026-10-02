import Foundation

/// Presentation groups retain the complete captured range used by live editing.
enum LiveTranscriptParagraphs {
    struct Part {
        let phrase: LiveTranscriptPhrase
        let provisional: Bool
        let textRange: NSRange
    }
    struct Paragraph {
        var phrase: LiveTranscriptPhrase
        var parts: [Part]
    }

    static func groups(
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase],
        overrides: [LiveTranscriptOverride] = []
    ) -> [Paragraph] {
        let rows = LiveTranscriptPresentation.rows(finalized: finalized, partials: partials)
        var result: [Paragraph] = []
        func protected(_ phrase: LiveTranscriptPhrase) -> Bool {
            phrase.isUserEdited || phrase.hasUnresolvedTiming || phrase.keepsParagraphBoundary == true
                || overrides.contains { $0.anchor.overlaps(phrase) }
        }
        for row in rows {
            let phrase = row.phrase
            if var previous = result.last,
                let last = previous.parts.last,
                !last.provisional, !protected(last.phrase), !protected(phrase),
                previous.phrase.source == phrase.source, previous.phrase.session == phrase.session,
                previous.phrase.speakerIdentity == phrase.speakerIdentity,
                previous.phrase.speakerLabel == phrase.speakerLabel,
                previous.phrase.personID == phrase.personID,
                phrase.start >= previous.phrase.end, phrase.start - previous.phrase.end <= 0.8,
                phrase.end - previous.phrase.start <= 30,
                previous.phrase.text.utf16.count + phrase.text.utf16.count <= 2000,
                !endsSentence(previous.phrase.text)
            {
                let separator = separator(previous.phrase.text, phrase.text)
                let offset = previous.phrase.text.utf16.count + separator.utf16.count
                previous.phrase.text += separator + phrase.text
                previous.phrase.end = phrase.end
                previous.phrase.words += phrase.words
                previous.phrase.recognizedFinal = !row.provisional
                previous.parts.append(
                    Part(
                        phrase: phrase, provisional: row.provisional,
                        textRange: NSRange(location: offset, length: phrase.text.utf16.count)))
                result[result.count - 1] = previous
            }
            else {
                result.append(
                    Paragraph(
                        phrase: phrase,
                        parts: [
                            Part(
                                phrase: phrase, provisional: row.provisional,
                                textRange: NSRange(location: 0, length: phrase.text.utf16.count))
                        ]))
            }
        }
        return result
    }

    static func joinedText(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            result += separator(result, part) + part
        }
        return result
    }

    private static func endsSentence(_ text: String) -> Bool {
        let ending = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}」』】"))
        return ending.last.map { ".!?。！？".contains($0) } ?? false
    }

    private static func separator(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first,
            !last.isWhitespace, !first.isWhitespace
        else { return "" }
        if ",.;:!?，。；：！？、)]}」』】".contains(first) { return "" }
        func cjk(_ character: Character) -> Bool {
            character.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
            }
        }
        return cjk(last) || cjk(first) ? "" : " "
    }
}
