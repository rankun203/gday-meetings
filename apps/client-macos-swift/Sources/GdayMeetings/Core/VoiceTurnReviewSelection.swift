import Foundation

/// Attribution keeps every turn. Review proposes a bounded excerpt from each
/// detected cluster, and naming that proposal covers only its displayed evidence.
enum VoiceTurnReviewSelection {
    private struct Key: Hashable {
        var meetingID: UUID
        var audioRevision: String?
        var audioFile: String?
        var source: String
        var detectedSpeaker: String
    }

    static func select(_ examples: [VoiceExample]) -> [VoiceExample] {
        let decisions = VoiceExactReviewDecisions(examples)
        var selected: [Key: VoiceExample] = [:]
        var retained = Set<UUID>()
        for example in examples {
            guard example.attributionTurn != nil else {
                retained.insert(example.id)
                continue
            }
            // Authored decisions and linkage retain their exact membership.
            // A machine suggestion alone never establishes a reviewed group.
            if example.isReviewed || example.namedPersonID != nil || example.personID != nil
                || example.manuallyGrouped || example.selectedReference != nil
            {
                retained.insert(example.id)
                continue
            }
            let effective = decisions.applying(to: example)
            guard !effective.manuallyCleared, !effective.excluded else { continue }
            let key = Key(
                meetingID: example.meetingID, audioRevision: example.audioRevision,
                audioFile: example.audioFile, source: example.source,
                detectedSpeaker: example.detectedSpeakerID ?? example.speakerID.uuidString)
            if let prior = selected[key], !preferred(example, to: prior) { continue }
            selected[key] = example
        }
        retained.formUnion(selected.values.map(\.id))
        return examples.filter { retained.contains($0.id) }
    }

    private static func preferred(_ candidate: VoiceExample, to current: VoiceExample) -> Bool {
        let candidateQuality = candidate.currentSampleQuality.map { $0.issue == nil } == true
        let currentQuality = current.currentSampleQuality.map { $0.issue == nil } == true
        if candidateQuality != currentQuality { return candidateQuality }
        let candidateDuration = candidate.range?.speechDuration ?? 0
        let currentDuration = current.range?.speechDuration ?? 0
        if candidateDuration != currentDuration { return candidateDuration > currentDuration }
        return candidate.id.uuidString < current.id.uuidString
    }
}
