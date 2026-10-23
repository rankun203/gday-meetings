import Foundation

/// Reading groups restore original recognition passages while retaining every canonical attribution.
enum TranscriptPassagePresentation {
    private struct SupportedIdentity: Equatable {
        var speakerID: UUID
        var personID: UUID?
    }

    static func groups(
        _ rows: [TranscriptSegment], speakers: [MeetingSpeaker], analysis _: LocalDiarizationResult?
    ) -> [[TranscriptSegment]] {
        let metadata = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        var groups: [[TranscriptSegment]] = []
        var groupSpeakerID: SupportedIdentity?
        for row in rows {
            guard let last = groups.last?.last,
                !protected(row, speaker: row.speakerID.flatMap { metadata[$0] }),
                !protected(last, speaker: last.speakerID.flatMap { metadata[$0] }),
                row.source == last.source, row.session == last.session,
                row.analysisTrackID == last.analysisTrackID,
                let left = originalRange(last), let right = originalRange(row),
                left.rowID == right.rowID,
                left.range.location + left.range.length == right.range.location,
                canContinue(groupSpeakerID, with: supportedIdentity(row, metadata: metadata))
            else {
                groups.append([row])
                groupSpeakerID = supportedIdentity(row, metadata: metadata)
                continue
            }
            // Unresolved words remain constituents, so playback, editing and correction
            // retain their exact target. Only supported voice changes split the passage.
            groups[groups.count - 1].append(row)
            if let next = supportedIdentity(row, metadata: metadata), groupSpeakerID?.personID == nil {
                groupSpeakerID = next
            }
        }
        return groups
    }

    private static func originalRange(_ row: TranscriptSegment) -> TranscriptSourceSpan? {
        guard let anchors = row.sourceSpans, let first = anchors.first,
            anchors.map({ ($0.separatorBefore ?? "") + $0.text }).joined() == row.text
        else { return nil }
        var end = first.range.location
        for anchor in anchors {
            guard anchor.rowID == first.rowID, (anchor.separatorBefore ?? "").isEmpty,
                anchor.range.location == end, anchor.range.length == anchor.text.utf16.count,
                anchor.range.location <= Int.max - anchor.range.length
            else { return nil }
            end = anchor.range.location + anchor.range.length
        }
        var combined = first
        combined.range.length = end - first.range.location
        return combined
    }

    private static func canContinue(_ group: SupportedIdentity?, with next: SupportedIdentity?) -> Bool {
        guard let group, let next else { return true }
        return group.speakerID == next.speakerID
            && (group.personID == nil || next.personID == nil || group.personID == next.personID)
    }

    private static func supportedIdentity(_ row: TranscriptSegment, metadata: [UUID: MeetingSpeaker])
        -> SupportedIdentity?
    {
        guard row.associationUncertain != true, row.sourcePlaceholder != true, let id = row.speakerID else {
            return nil
        }
        let speaker = metadata[id]
        return .init(
            speakerID: speaker?.voiceReviewOrigin?.speakerID ?? id,
            personID: speaker?.personID)
    }

    private static func protected(_ row: TranscriptSegment, speaker: MeetingSpeaker?) -> Bool {
        row.personID != nil || speaker?.passageAssignmentOrigin != nil
            || (speaker?.personID != nil && speaker?.voiceReviewOrigin == nil && speaker?.manuallyAssigned != true)
    }

    static func separator(_ left: String, _ right: String) -> String {
        guard left.last?.isWhitespace != true, right.first?.isWhitespace != true,
            let first = right.unicodeScalars.first,
            !CharacterSet.punctuationCharacters.contains(first)
        else { return "" }
        return " "
    }
}
