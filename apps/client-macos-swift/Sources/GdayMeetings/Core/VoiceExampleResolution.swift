import Foundation

/// Resolves source metadata only. Finding speech is not identity confirmation and
/// does not establish that a historical embedding describes the selected excerpt.
enum VoiceExampleResolution {
    struct Result {
        var speakerID: UUID
        var range: VoiceSampleRange?
        var firstPassage: VoiceSampleRange?
        var unavailableReason: String?
    }

    static func resolve(_ example: VoiceExample, meeting: Meeting) -> Result? {
        if !meeting.speakers.contains(where: { $0.id == example.speakerID }) {
            let projections = meeting.speakers.filter { $0.voiceReviewOrigin?.speakerID == example.speakerID }
            if let first = projections.first {
                let files = projections.compactMap { sourceFile(for: $0, meeting: meeting) }
                guard files.count == projections.count, Set(files).count == 1 else { return nil }
                var restored = meeting
                let projectedIDs = Set(projections.map(\.id))
                var original = first
                original.id = example.speakerID
                original.voiceReviewOrigin = nil
                original.voiceReviewExampleID = nil
                original.voiceSampleRange = nil
                original.voiceSampleRevision = nil
                restored.speakers.removeAll { projectedIDs.contains($0.id) }
                restored.speakers.append(original)
                for index in restored.transcript.indices {
                    if let identity = restored.transcript[index].speakerID, projectedIDs.contains(identity) {
                        restored.transcript[index].speakerID = original.id
                    }
                }
                return resolve(example, meeting: restored)
            }
        }
        let speaker: MeetingSpeaker
        if let exact = meeting.speakers.first(where: { $0.id == example.speakerID && $0.canAssignPerson }) {
            speaker = exact
        }
        else {
            let historical = example.embeddings
            let matches = meeting.speakers.filter { candidate in
                candidate.canAssignPerson && candidate.voiceReviewOrigin == nil
                    && historical.contains { vector in
                        guard SpeakerRecognition.isValid(vector.values), let stored = candidate.resolvedVoiceEmbedding,
                            stored.values == vector.values
                        else { return false }
                        if vector.type.supportsMatching || stored.type.supportsMatching {
                            return vector.type == stored.type && vector.isValid && stored.isValid
                        }
                        return vector.provenance != nil && vector.provenance == stored.provenance
                    }
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            speaker = match
        }
        guard let file = sourceFile(for: speaker, meeting: meeting) else {
            return .init(
                speakerID: speaker.id,
                unavailableReason: meeting.audioFiles.isEmpty
                    ? "The recording has no saved audio."
                    : "The original audio source could not be identified among this recording’s audio files.")
        }
        let source =
            sourceName(speaker.track) == "unknown"
            ? LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: file)) : sourceName(speaker.track)
        let rows = meeting.transcript.filter {
            $0.speakerID == speaker.id && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start
        }
        let first = rows.min { $0.start < $1.start }.map {
            VoiceSampleRange(audioFile: file, source: source, start: $0.start, end: min($0.end, $0.start + 10))
        }
        if var exact = speaker.voiceSampleRange, exact.isValid, exact.audioFile == file {
            exact.source = source
            // Disjoint physical support already bounds actual speech. Clamping
            // its envelope would leave the later fragments outside that envelope.
            if exact.spans == nil { exact.end = min(exact.end, exact.start + 10) }
            return .init(speakerID: speaker.id, range: exact, firstPassage: first)
        }
        let clear = rows.filter { $0.end - $0.start >= 2 }.sorted { $0.end - $0.start > $1.end - $1.start }.first {
            row in
            !meeting.transcript.contains { other in
                guard other.speakerID != speaker.id, other.start < row.end, other.end > row.start else { return false }
                guard let competitor = meeting.speakers.first(where: { $0.id == other.speakerID }),
                    let otherFile = sourceFile(for: competitor, meeting: meeting)
                else { return true }
                return otherFile == file
            }
        }.map {
            VoiceSampleRange(audioFile: file, source: source, start: $0.start, end: min($0.end, $0.start + 10))
        }
        return .init(
            speakerID: speaker.id, range: clear, firstPassage: first,
            unavailableReason: first == nil ? "The saved transcript has no timed passage for this speaker." : nil)
    }

    static func sourceFile(for speaker: MeetingSpeaker, meeting: Meeting) -> String? {
        if let range = speaker.voiceSampleRange, range.isValid, meeting.audioFiles.contains(range.audioFile) {
            return range.audioFile
        }
        if speaker.track.hasPrefix("track"), let index = Int(speaker.track.dropFirst(5)),
            meeting.audioFiles.indices.contains(index)
        {
            return meeting.audioFiles[index]
        }
        let source = sourceName(speaker.track)
        let files = meeting.audioFiles.filter {
            LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == source && source != "unknown"
        }
        if files.count == 1 { return files[0] }
        guard meeting.audioFiles.count == 1, let sole = meeting.audioFiles.first else { return nil }
        let soleSource = LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: sole))
        guard source == "unknown" || soleSource == "unknown" || source == soleSource else { return nil }
        return sole
    }

    private static func sourceName(_ track: String) -> String {
        switch track.lowercased() {
        case "mic", "microphone": "microphone"
        case "sys", "system", "system_mix": "system"
        default: "unknown"
        }
    }
}
