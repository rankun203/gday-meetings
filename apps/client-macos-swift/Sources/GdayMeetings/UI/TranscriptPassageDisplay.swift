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
        let supported = zip(rows, segments).filter {
            $0.0.speakerID != nil && !$0.0.isSourcePlaceholder && $0.1.associationUncertain != true
        }.map(\.0)
        let label =
            supported.first(where: { $0.transcriptAssociationTier == .tentative })
            ?? supported.first(where: { $0.personID != nil }) ?? supported.first ?? first
        var composed = Self(
            id: first.id, start: first.start, end: rows.map(\.end).max() ?? last.end, speaker: label.speaker,
            speakerID: label.speakerID, text: text, personID: label.personID,
            speakerColorIndex: label.speakerColorIndex, speakerColorKey: label.speakerColorKey,
            accessibilityHelp: rows.contains(where: { $0.speakerID == nil })
                ? "Some words have no speaker label."
                : (label.personID != nil && rows.contains(where: { $0.personID == nil })
                    ? "Some words have no person match." : nil),
            isSourcePlaceholder: label.isSourcePlaceholder, source: first.source,
            transcriptAssociationTier: label.transcriptAssociationTier)
        composed.speakerSourceRowID = label.id
        composed.hasUnattributedWords = composed.accessibilityHelp != nil
        composed.constituents = rows
        composed.constituentTextRanges = ranges
        return composed
    }
}
