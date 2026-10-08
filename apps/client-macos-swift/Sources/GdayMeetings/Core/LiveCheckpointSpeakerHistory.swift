import Foundation

/// Compact saved metadata by reachability, never by an arbitrary speaker limit.
/// Raw activity and embedding evidence remain in the separate evidence journal.
enum LiveCheckpointSpeakerHistory {
    static func compact(
        _ timeline: LiveSpeakerTimeline, referenced: Set<UUID>,
        overrides: [LiveTranscriptOverride], finished: Bool
    ) -> LiveSpeakerTimeline {
        var result = timeline
        var retained = referenced
        let activeGenerations = Set(timeline.cursors.map(\.generation))
        for speaker in timeline.speakers {
            if speaker.manuallyAssigned || speaker.personID != nil || speaker.voiceEmbedding != nil
                || speaker.manualReviewThrough != nil
                || (!finished && activeGenerations.contains(speaker.generation))
            {
                retained.insert(speaker.id)
            }
        }
        for change in overrides {
            if let id = change.anchor.speakerIdentity { retained.insert(id) }
            if let id = change.scopedSpeakerIdentity { retained.insert(id) }
        }
        // Keep the complete alias path, including intermediate nodes without
        // metadata. Each node is visited once; malformed cycles stay bounded.
        let aliases = timeline.identityAliases ?? [:]
        var pending = Array(retained)
        while let id = pending.popLast() {
            guard let target = aliases[id] else { continue }
            if retained.insert(target).inserted { pending.append(target) }
        }
        result.speakers = timeline.speakers.filter { retained.contains($0.id) }
        result.identityAliases = timeline.identityAliases.map { $0.filter { retained.contains($0.key) } }
        let generations = Set(result.speakers.map(\.generation)).union(activeGenerations)
        result.retiredGenerations = timeline.retiredGenerations.map { values in
            var seen = Set<UUID>()
            return values.filter { generations.contains($0) && seen.insert($0).inserted }
        }
        // The row file and recent segments already contain committed attribution.
        result.intervals = []
        return result
    }
}
