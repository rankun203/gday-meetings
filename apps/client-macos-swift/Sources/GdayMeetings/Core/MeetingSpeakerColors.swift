import Foundation

enum MeetingSpeakerColors {
    static func identity(_ speaker: MeetingSpeaker) -> UUID {
        if let source = speaker.sourcePlaceholder {
            return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, source == .microphone ? 1 : 2))
        }
        guard let origin = speaker.voiceReviewOrigin else { return speaker.id }
        // Projection IDs identify individual passages. One corrected voice keeps
        // one color across those passages, while distinct people remain distinct.
        let unassigned = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        return VoiceProjectionOrigin.identity(exampleID: origin.speakerID, segmentID: speaker.personID ?? unassigned)
    }

    /// Existing identities reserve their slots before newly observed speakers.
    /// Read-only callers derive the same fallback without changing the recording.
    static func slots(for speakers: [MeetingSpeaker], previous: [MeetingSpeaker] = []) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var used = Set<Int>()
        let prior = previous.isEmpty ? [:] : slots(for: previous)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let ordered = speakers.sorted { identity($0).uuidString < identity($1).uuidString }
        func reserve(_ slot: Int?, for key: UUID) {
            if result[key] == nil, let slot, slot >= 0, !used.contains(slot) {
                result[key] = slot
                used.insert(slot)
            }
        }
        for speaker in ordered { reserve(prior[identity(speaker)], for: identity(speaker)) }
        for speaker in ordered {
            let previousSlot = previousByID[speaker.id].flatMap { prior[identity($0)] }
            let inheritedSlot = speaker.voiceReviewOrigin.flatMap { prior[$0.speakerID] }
            reserve(previousSlot ?? speaker.colorSlot ?? inheritedSlot, for: identity(speaker))
        }
        for speaker in ordered where result[identity(speaker)] == nil {
            var slot = 0
            while used.contains(slot) { slot += 1 }
            result[identity(speaker)] = slot
            used.insert(slot)
        }
        return result
    }

    static func assigning(_ meeting: Meeting, previous: Meeting? = nil) -> Meeting {
        let allocation = slots(for: meeting.speakers, previous: previous?.speakers ?? [])
        var result = meeting
        for index in result.speakers.indices {
            result.speakers[index].colorSlot = allocation[identity(result.speakers[index])]
        }
        return result
    }
}
