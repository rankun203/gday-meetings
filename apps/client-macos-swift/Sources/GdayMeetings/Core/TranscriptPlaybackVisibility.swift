import Foundation

/// A presentation filter. Muting never changes the saved transcript or its history.
struct TranscriptPlaybackVisibility: Equatable {
    var meetingID: UUID?
    var audioFiles: [String]
    var mutedTracks: Set<Int>

    func hiddenSegments(
        meetingID: UUID, segments: [TranscriptSegment], speakers: [MeetingSpeaker], audioFiles: [String]
    ) -> Set<UUID> {
        guard self.meetingID == meetingID, !mutedTracks.isEmpty else { return [] }
        let tracks = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.track) })
        let playbackSources = self.audioFiles.map { Self.source($0, isFile: true) }
        return Set(
            segments.compactMap { segment in
                let track = segment.speakerID.flatMap { tracks[$0] } ?? ""
                // Provider ordinals refer to library files, not the currently playable
                // subset. A missing file must not shift another source into its slot.
                if track.hasPrefix("track"), let index = Int(track.dropFirst(5)), audioFiles.indices.contains(index) {
                    guard let playbackIndex = self.audioFiles.firstIndex(of: audioFiles[index]) else { return nil }
                    return mutedTracks.contains(playbackIndex) ? segment.id : nil
                }
                guard let source = segment.source ?? Self.source(track, isFile: false) else { return nil }
                let candidates = playbackSources.indices.filter { playbackSources[$0] == source }
                // Unknown provenance stays readable. Multiple files with one source
                // are hidden only when none of those files can be heard.
                return !candidates.isEmpty && candidates.allSatisfy(mutedTracks.contains) ? segment.id : nil
            })
    }

    private static func source(_ value: String, isFile: Bool) -> LiveAudioSource? {
        let name = isFile ? URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent : value
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mic", "microphone": return .microphone
        case "sys", "system", "system_mix": return .system
        default: return nil
        }
    }
}
