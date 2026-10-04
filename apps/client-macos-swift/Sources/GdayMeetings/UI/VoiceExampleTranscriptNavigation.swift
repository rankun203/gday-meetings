import Foundation

/// A recording link reveals related text without changing the shared player.
enum VoiceExampleTranscriptNavigation {
    static func rowID(for example: VoiceExample, meeting: Meeting) -> UUID? {
        let rows = meeting.transcript.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        let speakerIDs = Set(
            meeting.speakers.filter {
                $0.id == example.speakerID || $0.voiceReviewOrigin?.speakerID == example.speakerID
            }.map(\.id)
        ).union([example.speakerID])
        let attributed = rows.filter { $0.speakerID.map(speakerIDs.contains) ?? false }
        if let range = example.range ?? example.firstPassage {
            let overlaps: (TranscriptSegment) -> Bool = { $0.start < range.end && $0.end > range.start }
            if let row = attributed.first(where: overlaps) { return row.id }
            // Discovery has its own speaker IDs. Time and source can still locate
            // the existing text without claiming that a different voice matches.
            if let row = rows.first(where: { row in
                overlaps(row) && audioFile(for: row, meeting: meeting) == range.audioFile
            }) {
                return row.id
            }
        }
        return attributed.first?.id
    }

    private static func audioFile(for row: TranscriptSegment, meeting: Meeting) -> String? {
        if meeting.audioFiles.count == 1 { return meeting.audioFiles.first }
        guard let speaker = meeting.speakers.first(where: { $0.id == row.speakerID }) else { return nil }
        if speaker.track.hasPrefix("track"), let index = Int(speaker.track.dropFirst(5)),
            meeting.audioFiles.indices.contains(index)
        {
            return meeting.audioFiles[index]
        }
        let files = meeting.audioFiles.filter { file in
            let source = LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: file))
            return source == speaker.track || (source == "microphone" && speaker.track == "mic")
                || (source == "system" && (speaker.track == "sys" || speaker.track == "system_mix"))
        }
        return files.count == 1 ? files.first : nil
    }
}
