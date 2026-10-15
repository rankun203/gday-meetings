import CryptoKit
import Foundation

/// Acoustic turns determine grouping. Recognition rows provide exact, anchored text only.
enum DiarizedTranscriptProjection {
    private struct UnresolvedKey: Equatable {
        var overlappingTurns: [Int]
        var gapCell: Int?
    }

    private struct Piece {
        var row: TranscriptSegment
        var turn: Int?
        var unresolvedKey: UnresolvedKey?
        var track: String
        var order = 0
    }

    static func applying(_ result: LocalDiarizationResult, to meeting: Meeting, fileCount: Int) -> Meeting {
        let speakers = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        let turns = result.acousticAnalysis.turns.sorted {
            ($0.trackID, $0.start, $0.end, $0.speakerID) < ($1.trackID, $1.start, $1.end, $1.speakerID)
        }
        var pieces: [Piece] = []
        for row in meeting.transcript {
            let old = row.speakerID.flatMap { speakers[$0] }
            let protected =
                old?.protectsManualAssignment(to: row) == true
                || (old?.personID != nil && old?.manualReviewThrough == nil)
            let track: String? = {
                if let track = row.analysisTrackID { return track }
                if let track = old?.track, track.hasPrefix("track") { return track }
                if fileCount == 1 { return "track0" }
                let source = row.source?.rawValue ?? old?.track
                let matches = result.trackSources.filter { $0.value == source }
                return matches.count == 1 ? matches.first?.key : nil
            }()
            guard !protected, let track, let timing = row.timing, timing.text == row.text, timing.isValid else {
                pieces.append(.init(row: row, track: track ?? ""))
                continue
            }
            let text = row.text as NSString
            var cursor = 0
            for (index, span) in timing.spans.enumerated() {
                // Keep every character. Untimed lexical gaps are explicit, not silently assigned.
                let prefix = text.substring(with: NSRange(location: cursor, length: span.range.location - cursor))
                let prefixIsDecoration = prefix.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
                }
                if !prefixIsDecoration, !prefix.isEmpty {
                    pieces.append(
                        piece(
                            row, range: NSRange(location: cursor, length: prefix.utf16.count),
                            start: index > 0 ? timing.spans[index - 1].end : row.start, end: span.start, track: track,
                            turn: nil, result: result))
                }
                let startOffset = prefixIsDecoration ? cursor : span.range.location
                var endOffset = span.range.location + span.range.length
                if index == timing.spans.count - 1 {
                    let suffix = text.substring(from: endOffset)
                    if suffix.unicodeScalars.allSatisfy({
                        CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
                    }) {
                        endOffset = text.length
                    }
                }
                let overlapping = turns.indices.filter {
                    turns[$0].trackID == track && turns[$0].start < span.end && turns[$0].end > span.start
                }
                let assignment = assignedTurn(for: span, track: track, overlapping: overlapping, turns: turns)
                let turn = assignment.index
                var part = piece(
                    row, range: NSRange(location: startOffset, length: endOffset - startOffset),
                    start: span.start, end: span.end, track: track, turn: turn.map { turns[$0] }, result: result)
                part.turn = turn
                if assignment.inferred { part.row.associationUncertain = true }
                if turn == nil {
                    // Interval identities distinguish separate occurrences of the same voice.
                    // Empty support also needs a gap identity so silence cannot bridge speech.
                    let gapCell =
                        overlapping.isEmpty
                        ? turns.filter { $0.trackID == track && $0.end <= span.start }.count : nil
                    part.unresolvedKey = .init(overlappingTurns: overlapping, gapCell: gapCell)
                }
                part.row.timing = .init(
                    text: part.row.text,
                    spans: [
                        .init(
                            range: .init(location: span.range.location - startOffset, length: span.range.length),
                            start: span.start, end: span.end, granularity: span.granularity)
                    ])
                pieces.append(part)
                cursor = endOffset
            }
            if cursor < text.length {
                pieces.append(
                    piece(
                        row, range: NSRange(location: cursor, length: text.length - cursor),
                        start: timing.spans.last?.end ?? row.start, end: row.end,
                        track: track, turn: nil, result: result))
            }
        }
        for index in pieces.indices { pieces[index].order = index }
        // Group within source tracks first, so simultaneous microphone speech does not split a system turn.
        var grouped: [Piece] = []
        for track in Set(pieces.map(\.track)).sorted() {
            var rows: [Piece] = []
            for part in pieces.filter({ $0.track == track }).sorted(by: {
                $0.row.start == $1.row.start ? $0.order < $1.order : $0.row.start < $1.row.start
            }) {
                if var previous = rows.last,
                    previous.row.session == part.row.session, previous.row.source == part.row.source,
                    previous.row.associationUncertain == part.row.associationUncertain,
                    (part.turn != nil && previous.turn == part.turn)
                        || canGroupUnresolved(previous, part, turns: turns),
                    previous.row.end <= part.row.start, previous.row.timing != nil, part.row.timing != nil
                {
                    let sameSource = previous.row.sourceSpans?.last?.rowID == part.row.sourceSpans?.first?.rowID
                    let separator =
                        sameSource || previous.row.text.last?.isWhitespace == true
                            || part.row.text.first?.isWhitespace == true ? "" : " "
                    let offset = previous.row.text.utf16.count + separator.utf16.count
                    previous.row.text += separator + part.row.text
                    previous.row.end = part.row.end
                    var appended = part.row.sourceSpans ?? []
                    if !appended.isEmpty {
                        appended[0].separatorBefore = separator + (appended[0].separatorBefore ?? "")
                    }
                    previous.row.sourceSpans = (previous.row.sourceSpans ?? []) + appended
                    previous.row.timing?.text = previous.row.text
                    previous.row.timing?.spans += (part.row.timing?.spans ?? []).map {
                        var span = $0
                        span.range.location += offset
                        return span
                    }
                    previous.row.id = identity(previous.row.sourceSpans ?? [], resultID: result.id)
                    rows[rows.count - 1] = previous
                }
                else {
                    rows.append(part)
                }
            }
            grouped += rows
        }
        var updated = meeting
        updated.transcript = grouped.sorted {
            $0.row.start == $1.row.start ? $0.order < $1.order : $0.row.start < $1.row.start
        }.map(\.row)
        let used = Set(updated.transcript.compactMap(\.speakerID))
        var retained = meeting.speakers.filter { used.contains($0.id) }
        for speaker in result.speakers
        where used.contains(speaker.id)
            || (speaker.resolvedVoiceEmbedding?.isValid == true && speaker.voiceSampleRange?.isValid == true)
        {
            if !retained.contains(where: { $0.id == speaker.id }) { retained.append(speaker) }
        }
        updated.replaceSpeakers(retained)
        return updated
    }

    /// Small alignment offsets at an adjacent turn boundary must not discard a
    /// clearly supported word. Never choose a winner during simultaneous speech,
    /// or subdivide a coarse native run into fabricated word timestamps.
    private static func assignedTurn(
        for span: TranscriptTimedSpan, track: String, overlapping: [Int], turns: [AcousticSpeakerTurn]
    ) -> (index: Int?, inferred: Bool) {
        let identities = Set(overlapping.map { turns[$0].speakerID })
        let midpoint = (span.start + span.end) / 2
        if identities.count == 1,
            let index = overlapping.first(where: { turns[$0].start <= midpoint && turns[$0].end > midpoint })
        {
            return (index, false)
        }
        guard span.granularity == .word, span.end - span.start <= 1.5 else { return (nil, false) }
        if !overlapping.isEmpty {
            // Genuine overlap is uncertain even if one turn extends further.
            for left in overlapping {
                for right in overlapping where left < right && turns[left].speakerID != turns[right].speakerID {
                    if min(span.end, turns[left].end, turns[right].end)
                        > max(span.start, turns[left].start, turns[right].start)
                    {
                        return (nil, false)
                    }
                }
            }
            let ranked = overlapping.sorted {
                min(span.end, turns[$0].end) - max(span.start, turns[$0].start)
                    > min(span.end, turns[$1].end) - max(span.start, turns[$1].start)
            }
            if let best = ranked.first {
                let support = min(span.end, turns[best].end) - max(span.start, turns[best].start)
                let duration = span.end - span.start
                // Native word intervals can include leading/trailing silence. A
                // single positive voice is useful evidence even when the midpoint
                // falls outside speech. Require both absolute and relative support;
                // do not promote a near-zero sliver or an arbitrarily long interval.
                let unsupportedLeading = max(0, turns[best].start - span.start)
                let unsupportedTrailing = max(0, span.end - turns[best].end)
                if identities.count == 1, support >= 0.1, support >= duration * 0.25,
                    max(unsupportedLeading, unsupportedTrailing) <= 0.75
                {
                    return (best, true)
                }
                if support >= duration * 0.75 {
                    return (best, true)
                }
            }
        }
        // Only fill a short hole bracketed by the same voice on this track.
        // No nearest-speaker extension at the beginning/end or across long silence.
        else if span.end - span.start <= 0.2 {
            let before = turns.indices.filter { turns[$0].trackID == track && turns[$0].end <= span.start }
                .max { turns[$0].end < turns[$1].end }
            let after = turns.indices.filter { turns[$0].trackID == track && turns[$0].start >= span.end }
                .min { turns[$0].start < turns[$1].start }
            if let before, let after, turns[before].speakerID == turns[after].speakerID,
                turns[after].start - turns[before].end <= 0.2
            {
                return (before, true)
            }
        }
        return (nil, false)
    }

    private static func canGroupUnresolved(_ previous: Piece, _ next: Piece, turns: [AcousticSpeakerTurn]) -> Bool {
        guard previous.turn == nil, next.turn == nil,
            let key = previous.unresolvedKey, key == next.unresolvedKey,
            previous.row.source == next.row.source, previous.row.session == next.row.session,
            previous.row.analysisTrackID == next.row.analysisTrackID,
            let left = previous.row.sourceSpans, let right = next.row.sourceSpans,
            let last = left.last, let first = right.first,
            last.rowID == first.rowID,
            left.allSatisfy({ $0.rowID == first.rowID && ($0.separatorBefore ?? "").isEmpty }),
            right.allSatisfy({ $0.rowID == first.rowID && ($0.separatorBefore ?? "").isEmpty }),
            last.range.location + last.range.length == first.range.location
        else { return false }
        // Keep acoustic boundaries even when they fall between recognized tokens.
        return !turns.contains { turn in
            turn.trackID == next.track
                && ((turn.start >= previous.row.end && turn.start <= next.row.start)
                    || (turn.end >= previous.row.end && turn.end <= next.row.start))
        }
    }

    private static func piece(
        _ original: TranscriptSegment, range: NSRange, start: Double, end: Double,
        track: String, turn: AcousticSpeakerTurn?, result: LocalDiarizationResult
    ) -> Piece {
        var row = original
        row.text = (original.text as NSString).substring(with: range)
        row.start = start
        row.end = max(start, end)
        row.timing = nil
        row.sourceSpans = sourceSpans(original, range: range)
        row.id = identity(row.sourceSpans ?? [], resultID: result.id)
        if let turn, let speaker = result.speakers.first(where: { $0.track == track && $0.label == turn.speakerID }) {
            row.speakerID = speaker.id
            row.speaker = speaker.label
            row.sourcePlaceholder = false
            row.personID = nil
            row.associationUncertain = turn.associationUncertain
        }
        else {
            row.speakerID = nil
            row.speaker = row.source?.shortLabel ?? "Speaker"
            row.sourcePlaceholder = true
            row.personID = nil
            row.associationUncertain = true
        }
        return .init(row: row, track: track)
    }

    private static func sourceSpans(_ row: TranscriptSegment, range: NSRange) -> [TranscriptSourceSpan] {
        guard let anchors = row.sourceSpans,
            anchors.map({ ($0.separatorBefore ?? "") + $0.text }).joined() == row.text
        else {
            return [
                .init(
                    rowID: row.id, range: .init(location: range.location, length: range.length),
                    text: (row.text as NSString).substring(with: range))
            ]
        }
        var cursor = 0
        var pendingSeparator = ""
        var result: [TranscriptSourceSpan] = []
        for anchor in anchors {
            let separator = anchor.separatorBefore ?? ""
            let separatorRange = NSIntersectionRange(range, NSRange(location: cursor, length: separator.utf16.count))
            if separatorRange.length > 0 {
                pendingSeparator += (separator as NSString).substring(
                    with:
                        NSRange(location: separatorRange.location - cursor, length: separatorRange.length))
            }
            cursor += separator.utf16.count
            let overlap = NSIntersectionRange(range, NSRange(location: cursor, length: anchor.text.utf16.count))
            if overlap.length > 0 {
                let offset = overlap.location - cursor
                result.append(
                    .init(
                        rowID: anchor.rowID,
                        range: .init(location: anchor.range.location + offset, length: overlap.length),
                        text: (anchor.text as NSString).substring(
                            with: NSRange(location: offset, length: overlap.length)),
                        separatorBefore: pendingSeparator.isEmpty ? nil : pendingSeparator))
                pendingSeparator = ""
            }
            cursor += anchor.text.utf16.count
        }
        return result
    }

    private static func identity(_ spans: [TranscriptSourceSpan], resultID: UUID) -> UUID {
        let key =
            resultID.uuidString
            + spans.map { "\($0.rowID):\($0.range.location):\($0.range.length)" }.joined(separator: ":")
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
