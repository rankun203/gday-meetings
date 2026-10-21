import Foundation

/// Existing text and timing for the physical audio spans played by a sample.
/// Unresolved sources are omitted rather than borrowing simultaneous text from another track.
enum VoiceSampleTranscript {
    /// Identity changes do not change the audio whose transcript is displayed.
    struct Request: Equatable {
        let exampleID: UUID
        let meetingID: UUID
        let range: VoiceSampleRange?
        let audioRevision: String?
        init(_ example: VoiceExample) {
            exampleID = example.id
            meetingID = example.meetingID
            range = example.range
            audioRevision = example.audioRevision
        }
    }

    struct Passage: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            var rowID: UUID
            var textOffset: Int
        }
        var id: ID
        var text: String
        var start: Double
        var end: Double
        var timing: TranscriptTextTiming?
        var support: [SpeakerEvidenceSpan]

        func highlightedRanges(at time: Double?) -> [TranscriptTextRange] {
            guard let time, time.isFinite, support.contains(where: { $0.start <= time && time < $0.end }) else {
                return []
            }
            guard let timing else { return [] }
            return timing.spans.filter {
                $0.granularity == .word && $0.start <= time && time < $0.end
            }.map(\.range)
        }
    }

    static func passages(for example: VoiceExample, meeting: Meeting) throws -> [Passage] {
        guard example.meetingID == meeting.id, let range = example.range,
            meeting.audioFiles.contains(range.audioFile)
        else { return [] }
        let speakers = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        var result: [Passage] = []
        for row in meeting.transcript {
            try Task.checkCancellation()
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end > row.start,
                !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                sourceFile(for: row, speakers: speakers, audioFiles: meeting.audioFiles) == range.audioFile
            else { continue }
            let support = intersections(start: row.start, end: row.end, spans: range.supportSpans)
            guard !support.isEmpty else { continue }
            guard let timing = row.timing, timing.text == row.text, timing.isValid else {
                result.append(
                    .init(
                        id: .init(rowID: row.id, textOffset: 0), text: row.text,
                        start: row.start, end: row.end, support: support))
                continue
            }
            // Disjoint excerpts must not display words from skipped audio. Keep
            // consecutive native text spans together without estimating new timing.
            var groups: [[TranscriptTimedSpan]] = []
            var previousIndex: Int?
            for (index, span) in timing.spans.enumerated() {
                guard !intersections(start: span.start, end: span.end, spans: support).isEmpty else { continue }
                if previousIndex == index - 1, !groups.isEmpty {
                    groups[groups.count - 1].append(span)
                }
                else {
                    groups.append([span])
                }
                previousIndex = index
            }
            for group in groups {
                guard let first = group.first, let last = group.last else { continue }
                let textRange = NSRange(
                    location: first.range.location,
                    length: last.range.location + last.range.length - first.range.location)
                guard let sliced = timing.sliced(to: textRange) else { continue }
                result.append(
                    .init(
                        id: .init(rowID: row.id, textOffset: textRange.location), text: sliced.text,
                        start: first.start, end: group.map(\.end).max() ?? last.end,
                        timing: sliced, support: support))
            }
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.id.rowID != $1.id.rowID { return $0.id.rowID.uuidString < $1.id.rowID.uuidString }
            return $0.id.textOffset < $1.id.textOffset
        }
    }

    static func playbackTime(
        for example: VoiceExample, meetingID: UUID?, audioFile: String?,
        excerptRanges: [Range<Double>], time: Double
    ) -> Double? {
        guard meetingID == example.meetingID, let range = example.range,
            audioFile == range.audioFile, excerptRanges == range.supportSpans.map({ $0.start..<$0.end }),
            time.isFinite, excerptRanges.contains(where: { $0.contains(time) })
        else { return nil }
        return time
    }

    private static func intersections(start: Double, end: Double, spans: [SpeakerEvidenceSpan])
        -> [SpeakerEvidenceSpan]
    {
        spans.compactMap {
            let lower = max(start, $0.start)
            let upper = min(end, $0.end)
            return lower < upper ? .init(start: lower, end: upper) : nil
        }
    }

    private static func sourceFile(
        for row: TranscriptSegment, speakers: [UUID: MeetingSpeaker], audioFiles: [String]
    ) -> String? {
        let speaker = row.speakerID.flatMap { speakers[$0] }
        // Track ordinals identify the original saved file list, including files
        // that are currently missing. Never renumber the playable subset.
        if let track = row.analysisTrackID, track.hasPrefix("track"),
            let index = Int(track.dropFirst(5))
        {
            return audioFiles.indices.contains(index) ? audioFiles[index] : nil
        }
        if row.source == nil, let track = speaker?.track, track.hasPrefix("track"),
            let index = Int(track.dropFirst(5))
        {
            return audioFiles.indices.contains(index) ? audioFiles[index] : nil
        }
        let source = row.source?.rawValue ?? normalizedSource(speaker?.track)
        if let source {
            let matches = audioFiles.filter {
                LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == source
            }
            if matches.count == 1 { return matches[0] }
            // A single imported mixed file is the only physical source. A
            // conflicting known source, or multiple same-source files, is ambiguous.
            if audioFiles.count == 1,
                LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: audioFiles[0])) == "unknown"
            {
                return audioFiles[0]
            }
            return nil
        }
        return audioFiles.count == 1 ? audioFiles[0] : nil
    }

    private static func normalizedSource(_ track: String?) -> String? {
        switch track?.lowercased() {
        case "mic", "microphone": return "microphone"
        case "sys", "system", "system_mix": return "system"
        default: return nil
        }
    }
}
