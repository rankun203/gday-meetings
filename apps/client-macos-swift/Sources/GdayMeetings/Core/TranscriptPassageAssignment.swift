import Foundation

/// Undo information for an explicit passage review, independent of voice evidence.
struct TranscriptPassageOrigin: Codable, Equatable, Sendable {
    var speakerID: UUID?
    var speaker: String
    var personID: UUID?
    var associationUncertain: Bool?
    var speakerPersonID: UUID?
    var labelDecisionChanged: Bool?
}

enum TranscriptPassageAssignment {
    static func applying(to meeting: Meeting, rowID: UUID, personID: UUID?, people: Set<UUID>, restore: Bool = false)
        -> Meeting?
    {
        guard let index = meeting.transcript.firstIndex(where: { $0.id == rowID }),
            restore || personID == nil || people.contains(personID!)
        else { return nil }
        var result = meeting
        var row = result.transcript[index]
        let original = result.speakers.first { $0.id == row.speakerID }
        let baseline = original?.passageAssignmentOrigin
        let priorScopedID = baseline == nil ? nil : row.speakerID
        if restore {
            guard let origin = baseline else { return nil }
            let current = result.speakers.first { $0.id == origin.speakerID }
            row.speakerID = current?.id
            row.speaker = current?.label ?? origin.speaker
            row.associationUncertain = origin.associationUncertain
            // A later whole-label decision or deleted person wins over stale undo metadata.
            let labelChanged = origin.labelDecisionChanged == true || current?.personID != origin.speakerPersonID
            let candidate = labelChanged ? current?.personID : origin.personID
            row.personID = row.associationUncertain == true ? nil : candidate.flatMap { people.contains($0) ? $0 : nil }
        }
        else {
            let origin =
                baseline
                ?? TranscriptPassageOrigin(
                    speakerID: row.speakerID, speaker: row.speaker, personID: row.personID,
                    associationUncertain: row.associationUncertain, speakerPersonID: original?.personID)
            let scoped = MeetingSpeaker(
                label: row.speaker, track: row.source?.rawValue ?? original?.track ?? "unknown",
                providerName: "Passage review", personID: personID, confirmed: personID != nil,
                manuallyAssigned: true, colorSlot: original?.colorSlot, passageAssignmentOrigin: origin)
            result.speakers.append(scoped)
            row.speakerID = scoped.id
            // The unique metadata entry owns this review. Avoid a duplicate
            // row-level person ID that cannot follow paged People merges.
            row.personID = nil
            row.associationUncertain = nil
        }
        result.transcript[index] = row
        if let priorScopedID, !result.transcript.contains(where: { $0.speakerID == priorScopedID }) {
            result.speakers.removeAll { $0.id == priorScopedID }
        }
        return result
    }
}
