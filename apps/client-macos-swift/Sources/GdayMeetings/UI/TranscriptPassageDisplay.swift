import Foundation

extension TranscriptDisplayRow {
    static func passage(rows: [TranscriptDisplayRow], segments: [TranscriptSegment]) -> Self? {
        guard let first = rows.first, let last = rows.last, rows.count == segments.count else { return nil }
        guard rows.count > 1 else { return first }
        var text = ""
        var ranges: [NSRange] = []
        for (index, row) in rows.enumerated() {
            let left = index > 0 ? segments[index - 1].sourceSpans?.last : nil
            let right = segments[index].sourceSpans?.first
            let contiguous: Bool
            if let left, let right {
                contiguous =
                    left.rowID == right.rowID
                    && left.range.location <= Int.max - left.range.length
                    && left.range.location + left.range.length == right.range.location
            }
            else {
                contiguous = false
            }
            // Canonical continuation retains whitespace omitted by standalone display rows.
            let content = index == 0 ? row.text : segments[index].text
            let separator = index == 0 || contiguous ? "" : TranscriptPassagePresentation.separator(text, content)
            text += separator
            ranges.append(NSRange(location: text.utf16.count, length: content.utf16.count))
            text += content
        }
        var composed = Self(
            id: first.id, start: first.start, end: last.end, speaker: first.speaker,
            speakerID: first.speakerID, text: text, personID: first.personID,
            speakerColorIndex: first.speakerColorIndex, speakerColorKey: first.speakerColorKey,
            accessibilityHelp: rows.contains(where: { $0.speakerID == nil })
                ? "Some words have no speaker label." : nil,
            isSourcePlaceholder: first.isSourcePlaceholder, source: first.source,
            transcriptAssociationTier: first.transcriptAssociationTier)
        composed.constituents = rows
        composed.constituentTextRanges = ranges
        return composed
    }
}
