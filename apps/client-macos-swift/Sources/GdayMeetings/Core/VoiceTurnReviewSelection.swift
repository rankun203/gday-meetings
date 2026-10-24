import Foundation

/// Attribution keeps every turn. Review samples acoustically consistent groups
/// within each detected cluster; naming covers only the displayed evidence.
enum VoiceTurnReviewSelection {
    private struct Key: Hashable {
        var meetingID: UUID
        var audioRevision: String?
        var audioFile: String?
        var source: String
        var detectedSpeaker: String
        var namedPersonID: UUID?
        var rejectedPersonIDs: Set<UUID>
    }

    static func select(_ examples: [VoiceExample], policy: VoiceMatchingPolicy = .default) -> [VoiceExample] {
        let decisions = VoiceExactReviewDecisions(examples)
        var pending: [Key: [VoiceExample]] = [:]
        var retained = Set<UUID>()
        for example in examples {
            guard example.attributionTurn != nil else {
                retained.insert(example.id)
                continue
            }
            // Authored decisions and linkage retain their exact membership.
            // A machine suggestion alone never establishes a reviewed group.
            if example.isReviewed || example.personID != nil
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
                detectedSpeaker: example.detectedSpeakerID ?? example.speakerID.uuidString,
                namedPersonID: example.namedPersonID, rejectedPersonIDs: Set(effective.rejectedPersonIDs))
            // Missing representations carry no evidence that two turns share a voice.
            guard example.embeddings.contains(where: \.isValid) else {
                retained.insert(example.id)
                continue
            }
            pending[key, default: []].append(example)
        }
        for values in pending.values {
            for group in VoiceAutomaticGrouping.groups(values, policy: policy) {
                if let representative = group.sorted(by: preferred).first { retained.insert(representative.id) }
            }
        }
        return examples.filter { retained.contains($0.id) }
    }

    private static func preferred(_ candidate: VoiceExample, to current: VoiceExample) -> Bool {
        let candidatePriority = VoiceSampleQuality.priority(example: candidate)
        let currentPriority = VoiceSampleQuality.priority(example: current)
        if candidatePriority != currentPriority { return candidatePriority > currentPriority }
        let candidateQuality = candidate.currentSampleQuality.map { $0.issue == nil } == true
        let currentQuality = current.currentSampleQuality.map { $0.issue == nil } == true
        if candidateQuality != currentQuality { return candidateQuality }
        let candidateDuration = candidate.range?.speechDuration ?? 0
        let currentDuration = current.range?.speechDuration ?? 0
        if candidateDuration != currentDuration { return candidateDuration > currentDuration }
        return candidate.id.uuidString < current.id.uuidString
    }
}
