import Foundation

/// Captures the badge that opened the picker before a composed passage expands.
struct TranscriptSpeakerPickerContext: Equatable {
    let rowID: UUID
    let explanation: TranscriptSpeakerAssignmentExplanation

    init(displayedRow: TranscriptDisplayRow) {
        rowID = displayedRow.speakerSourceRowID ?? displayedRow.id
        explanation = .init(displayedRow: displayedRow)
    }
}

struct TranscriptSpeakerAssignmentExplanation: Equatable {
    enum DottedReason: Hashable {
        case tentativePerson
        case noAssignedPerson
        case wordsWithoutSpeaker
        case wordsWithoutPerson

        var text: String {
            switch self {
            case .tentativePerson: "The person match is tentative."
            case .noAssignedPerson: "No person is assigned to this passage."
            case .wordsWithoutSpeaker: "Some words in this passage have no speaker label."
            case .wordsWithoutPerson: "Some words in this passage have no person match."
            }
        }
    }

    let dottedReasons: [DottedReason]
    let automaticallyMatched: Bool
    var hasDottedOutline: Bool { !dottedReasons.isEmpty }

    static func hasDottedOutline(for row: TranscriptDisplayRow) -> Bool {
        row.canAssignPerson && (row.hasTentativePerson || row.personID == nil || row.hasUnattributedWords)
    }

    init(displayedRow row: TranscriptDisplayRow) {
        var reasons: [DottedReason] = []
        if row.canAssignPerson {
            if row.hasTentativePerson { reasons.append(.tentativePerson) }
            if row.personID == nil { reasons.append(.noAssignedPerson) }
            if row.hasUnattributedWords {
                reasons.append(
                    row.canonicalRows.contains(where: { $0.speakerID == nil })
                        ? .wordsWithoutSpeaker : .wordsWithoutPerson)
            }
        }
        dottedReasons = reasons
        automaticallyMatched = row.canAssignPerson && row.personID != nil && row.transcriptAssociationTier == .automatic
    }

    static func title(for speaker: MeetingSpeaker) -> String {
        "Assign Person · \(speaker.displayLabel.isEmpty ? "Unlabeled" : speaker.displayLabel)"
    }
}
