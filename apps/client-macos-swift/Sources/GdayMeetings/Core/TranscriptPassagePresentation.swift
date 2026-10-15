import Foundation
import NaturalLanguage

/// Reading groups retain canonical rows; display grouping never assigns an unresolved word to a voice.
enum TranscriptPassagePresentation {
    static func groups(
        _ rows: [TranscriptSegment], speakers: [MeetingSpeaker], analysis: LocalDiarizationResult?
    ) -> [[TranscriptSegment]] {
        guard let analysis else { return rows.map { [$0] } }
        let metadata = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        var groups: [[TranscriptSegment]] = []
        for row in rows {
            guard var previous = groups.last, let leading = previous.first, let last = previous.last,
                let speakerID = leading.speakerID, let speaker = metadata[speakerID],
                leading.sourcePlaceholder != true, !protected(leading, speaker: speaker),
                leading.timing?.text == leading.text, leading.timing?.isValid == true,
                row.speakerID == nil || row.speakerID == speakerID,
                !protected(row, speaker: row.speakerID.flatMap { metadata[$0] }),
                row.source == last.source, row.session == last.session,
                row.analysisTrackID == last.analysisTrackID,
                last.end <= row.start, hasExactSourceText(row),
                (row.timing?.text == row.text && row.timing?.isValid == true)
                    || (row.timing == nil
                        && row.text.unicodeScalars.allSatisfy {
                            CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
                        }),
                !endsSentence(previous.map(\.text).joined(), before: row.text),
                !analysis.ranges.contains(where: {
                    $0.track == speaker.track && $0.label != speaker.label
                        && $0.start < row.end && $0.end > last.end
                })
            else {
                groups.append([row])
                continue
            }
            // Only neighboring visible rows combine, preserving interleaved track order.
            previous.append(row)
            groups[groups.count - 1] = previous
        }
        return groups
    }

    private static func hasExactSourceText(_ row: TranscriptSegment) -> Bool {
        guard let anchors = row.sourceSpans, !anchors.isEmpty else { return false }
        return anchors.map { ($0.separatorBefore ?? "") + $0.text }.joined() == row.text
    }

    private static func protected(_ row: TranscriptSegment, speaker: MeetingSpeaker?) -> Bool {
        row.personID != nil || speaker?.protectsManualAssignment(to: row) == true
            || (speaker?.personID != nil && speaker?.manualReviewThrough == nil)
    }

    static func separator(_ left: String, _ right: String) -> String {
        guard left.last?.isWhitespace != true, right.first?.isWhitespace != true,
            let first = right.unicodeScalars.first,
            !CharacterSet.punctuationCharacters.contains(first)
        else { return "" }
        return " "
    }

    static func endsSentence(_ text: String, before continuation: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, ".!?。！？".contains(last) else { return false }
        let decimalContinuation =
            last == "." && trimmed.dropLast().last?.isNumber == true
            && continuation.first?.isNumber == true
        let combined = trimmed + (decimalContinuation ? "" : separator(trimmed, continuation)) + continuation
        let boundary = trimmed.count
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = combined
        var ended = false
        tokenizer.enumerateTokens(in: combined.startIndex..<combined.endIndex) { range, _ in
            let sentence = String(combined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if combined.distance(from: combined.startIndex, to: range.lowerBound) + sentence.count == boundary {
                ended = true
            }
            return !ended
        }
        return ended
    }
}
