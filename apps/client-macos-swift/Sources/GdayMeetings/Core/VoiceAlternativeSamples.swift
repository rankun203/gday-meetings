import Foundation

enum VoiceAlternativeSampleResult: Equatable, Sendable {
    case prepared(VoiceExample)
    case exhausted
    /// Older scans retained only their selected excerpt. A new scan retains all turns.
    case analysisUnavailable
    /// Analysis exists, but this excerpt cannot be mapped to one detected voice.
    case speakerUnresolved
}

/// Alternatives belong to one detected speaker on one track. They carry no identity decision.
enum VoiceAlternativeSamples {
    struct Selection: Sendable {
        var range: VoiceSampleRange?
        var detectedSpeakerID: String?
        var detectedSpeakerResultID: UUID?
        var detectedSpeakerSpans: [SpeakerEvidenceSpan]?
    }

    static func select(original: VoiceExample, analysis: LocalDiarizationResult, existing: [VoiceExample]) -> Selection?
    {
        guard let originalRange = original.range else { return nil }
        let matches = analysis.speakers.filter { speaker in
            guard let selected = speaker.voiceSampleRange, selected.audioFile == originalRange.audioFile else {
                return false
            }
            return originalRange.supportSpans.allSatisfy { span in
                analysis.ranges.contains {
                    $0.track == speaker.track && $0.label == speaker.label
                        && $0.start <= span.start + 1.0 / 16000
                        && $0.end + 1.0 / 16000 >= span.end
                }
            }
        }
        // A range shared by multiple model labels cannot establish which voice to reuse.
        guard matches.count == 1, let speaker = matches.first else { return nil }
        let turns = analysis.ranges.filter { $0.track == speaker.track && $0.label == speaker.label }
        guard !turns.isEmpty else { return nil }
        let used = existing.filter {
            $0.meetingID == original.meetingID && $0.audioRevision == original.audioRevision
        }.compactMap(\.range).filter { $0.audioFile == originalRange.audioFile }.flatMap(\.supportSpans)
        var candidates: [VoiceSampleRange] = []

        // Retained turns only establish detected overlap; final exclusive output cannot
        // establish an absence of mixed speech or support a perceptual quality claim.
        let otherVoices = analysis.ranges.filter {
            $0.track == speaker.track && $0.label != speaker.label
                && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }.map { SpeakerEvidenceSpan(start: $0.start, end: $0.end) }
        let unresolved = (analysis.unresolvedRanges ?? []).filter { $0.track == speaker.track }.map {
            SpeakerEvidenceSpan(start: $0.start, end: $0.end)
        }

        for turn in turns where turn.associationUncertain != true {
            if Task.isCancelled { return nil }
            guard turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start else { continue }
            let turnSpan = SpeakerEvidenceSpan(start: turn.start, end: turn.end)
            // Match initial selection: reject a whole turn when another voice or
            // unresolved speech overlaps it. Trimming uncertain boundaries would
            // imply precision the retained analysis cannot establish.
            guard !(otherVoices + unresolved).contains(where: { $0.isValid && turnSpan.overlaps($0) }) else {
                continue
            }
            var fragments = [turnSpan]
            for blocked in used where blocked.isValid {
                fragments = fragments.flatMap { span -> [SpeakerEvidenceSpan] in
                    guard span.overlaps(blocked) else { return [span] }
                    return [
                        SpeakerEvidenceSpan(start: span.start, end: min(span.end, blocked.start)),
                        SpeakerEvidenceSpan(start: max(span.start, blocked.end), end: span.end),
                    ].filter(\.isValid)
                }
            }
            for span in fragments {
                // Match the initial extraction's 16 kHz boundaries and ten-second cap.
                let start = (span.start * 16000).rounded(.up) / 16000
                let end = (min(span.end, start + 10) * 16000).rounded(.down) / 16000
                guard end - start >= 2 else { continue }
                candidates.append(
                    .init(
                        audioFile: originalRange.audioFile, source: originalRange.source, start: start, end: end))
            }
        }
        return .init(
            range: candidates.sorted {
                if $0.speechDuration != $1.speechDuration { return $0.speechDuration > $1.speechDuration }
                return $0.start < $1.start
            }.first,
            detectedSpeakerID: VoiceDetectedSpeakerScope.identity(speaker: speaker, analysis: analysis),
            detectedSpeakerResultID: analysis.id,
            detectedSpeakerSpans: VoiceDetectedSpeakerScope.spans(speaker: speaker, analysis: analysis))
    }
}

/// A review excerpt and its detected speaker have different temporal scopes.
/// Retain the latter so identity attribution is not limited to the excerpt.
enum VoiceDetectedSpeakerScope {
    static func identity(speaker: MeetingSpeaker, analysis: LocalDiarizationResult) -> String {
        "\(analysis.modelRevision)|\(speaker.track)|\(speaker.label)"
    }

    static func spans(speaker: MeetingSpeaker, analysis: LocalDiarizationResult) -> [SpeakerEvidenceSpan]? {
        let matching = analysis.ranges.filter {
            $0.track == speaker.track && $0.label == speaker.label && $0.associationUncertain != true
        }
        let valid = matching.map { SpeakerEvidenceSpan(start: $0.start, end: $0.end) }.filter(\.isValid)
        let ranges = valid.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [SpeakerEvidenceSpan] = []
        for range in ranges {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            }
            else {
                result.append(range)
            }
        }
        return result.isEmpty ? nil : result
    }
}
