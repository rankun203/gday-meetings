import Foundation

struct LiveSpeakerIdentity: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: LiveAudioSource
    var generation: UUID
    var slot: Int
    var model: String
    var revision: String
    var personID: UUID?
    var voiceEmbedding: TypedVoiceEmbedding?
    var activityPolicy: String?
    var manuallyAssigned = false
    var label: String { (source == .microphone ? "mic_" : "sys_") + String(format: "%02d", slot + 1) }
}

struct LiveSpeakerInterval: Codable, Equatable, Sendable {
    var speakerID: UUID
    var start: Double
    var end: Double
}

struct LiveSpeakerEvent: Sendable {
    var source: LiveAudioSource
    var generation: UUID
    var sequence: Int
    var speakers: [LiveSpeakerIdentity]
    var intervals: [LiveSpeakerInterval]
    var start: Double
    var end: Double
    var final = false
}

struct LiveSpeakerTimeline: Codable, Equatable {
    struct Cursor: Codable, Equatable {
        var source: LiveAudioSource
        var generation: UUID
        var sequence: Int
        var end: Double
        var final: Bool
    }
    var speakers: [LiveSpeakerIdentity] = []
    var intervals: [LiveSpeakerInterval] = []
    var cursors: [Cursor] = []
    var gaps: [LiveTranscriptGap] = []
    var retiredGenerations: [UUID]?

    @discardableResult mutating func accept(_ event: LiveSpeakerEvent) -> Bool {
        guard event.start.isFinite, event.end.isFinite, event.start >= 0, event.end >= event.start else { return false }
        guard !(retiredGenerations ?? []).contains(event.generation) else { return false }
        if let cursor = cursors.first(where: { $0.source == event.source }) {
            if cursor.generation == event.generation {
                guard !cursor.final, event.sequence > cursor.sequence, event.start >= cursor.end - 0.000_001 else {
                    return false
                }
            }
            else if event.sequence != 0 || event.start < cursor.end - 0.000_001 {
                return false
            }
        }
        else if event.sequence != 0 {
            return false
        }
        let ids = Set(event.speakers.map(\.id))
        guard event.speakers.allSatisfy({ $0.source == event.source && $0.generation == event.generation }),
            event.intervals.allSatisfy({
                ids.contains($0.speakerID) && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= event.start && $0.end <= event.end && $0.end > $0.start
            })
        else { return false }
        for speaker in event.speakers where !speakers.contains(where: { $0.id == speaker.id }) {
            speakers.append(speaker)
        }
        if let previous = cursors.first(where: { $0.source == event.source }), previous.generation != event.generation {
            retiredGenerations = (retiredGenerations ?? []) + [previous.generation]
        }
        cursors.removeAll { $0.source == event.source }
        cursors.append(
            .init(
                source: event.source, generation: event.generation,
                sequence: event.sequence, end: event.end, final: event.final))
        // Events contain only newly emitted activity; adjacent chunks join by identity.
        for interval in event.intervals {
            if let index = intervals.lastIndex(where: { $0.speakerID == interval.speakerID }),
                intervals[index].end >= interval.start - 0.000_001
            {
                intervals[index].end = max(intervals[index].end, interval.end)
            }
            else {
                intervals.append(interval)
            }
        }
        return true
    }

    mutating func retainEmbedding(_ embedding: TypedVoiceEmbedding, for speakerID: UUID) {
        guard embedding.isValid, let index = speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        speakers[index].voiceEmbedding = embedding
    }

    mutating func assign(_ personID: UUID?, to speakerID: UUID, manual: Bool) {
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }),
            manual || !speakers[index].manuallyAssigned
        else { return }
        speakers[index].personID = personID
        speakers[index].manuallyAssigned = manual
    }

    /// Keep overlap unresolved. A name requires one identity covering most of a
    /// timed word; missing timing never invents a new word boundary.
    func attributing(_ phrase: LiveTranscriptPhrase, preceding: LiveTranscriptPhrase? = nil) -> [LiveTranscriptPhrase] {
        let ids = Set(speakers.filter { $0.source == phrase.source }.map(\.id))
        let sourceIntervals = intervals.filter { ids.contains($0.speakerID) }
        let relevant = sourceIntervals.filter { $0.start < phrase.end && $0.end > phrase.start }
        func identity(_ start: Double, _ end: Double, activity: [LiveSpeakerInterval]) -> LiveSpeakerIdentity? {
            let duration = end - start
            guard duration > 0 else { return nil }
            var coverage: [UUID: Double] = [:]
            for interval in activity {
                coverage[interval.speakerID, default: 0] += max(0, min(end, interval.end) - max(start, interval.start))
            }
            let active = coverage.filter { $0.value > duration * 0.1 }
            guard active.count == 1, let winner = active.first, winner.value >= duration * 0.6 else { return nil }
            return speakers.first { $0.id == winner.key }
        }
        func apply(_ identity: LiveSpeakerIdentity?, to row: LiveTranscriptPhrase) -> LiveTranscriptPhrase {
            var row = row
            if let identity {
                row.speakerIdentity = identity.id
                row.diarizationLabel = identity.label
                row.personID = identity.personID
                row.voiceEmbedding = identity.voiceEmbedding
            }
            else if !ids.isEmpty {
                row.diarizationLabel = phrase.source == .microphone ? "mic_?" : "sys_?"
                row.speakerIdentity = nil
                row.personID = nil
                row.voiceEmbedding = nil
            }
            return row
        }
        guard !relevant.isEmpty else { return [apply(nil, to: phrase)] }
        guard phrase.hasCompleteWordTiming else {
            return [apply(identity(phrase.start, phrase.end, activity: relevant), to: phrase)]
        }
        var precedingEvidence: (Double, Double, LiveSpeakerIdentity?)?
        if let preceding, preceding.source == phrase.source, preceding.session == phrase.session,
            preceding.hasCompleteWordTiming, preceding.end <= phrase.start,
            phrase.start - preceding.end <= 0.5
        {
            let precedingActivity = sourceIntervals.filter {
                $0.start < preceding.end && $0.end > preceding.start
            }
            // Use observed word attribution, not a previously inferred bridge.
            for word in preceding.words.reversed() {
                guard let speaker = identity(word.start, word.end, activity: precedingActivity) else { break }
                if let current = precedingEvidence {
                    guard current.2?.id == speaker.id else { break }
                    precedingEvidence?.0 = word.start
                }
                else {
                    precedingEvidence = (word.start, word.end, speaker)
                }
            }
        }
        var groups: [(Double, Double, LiveSpeakerIdentity?)] = []
        for word in phrase.words {
            let speaker = identity(word.start, word.end, activity: relevant)
            if let last = groups.last, last.2?.id == speaker?.id {
                groups[groups.count - 1].1 = word.end
            }
            else {
                groups.append((word.start, word.end, speaker))
            }
        }
        // Short unassigned boundary words may reflect an activity threshold gap.
        // Never bridge overlap, a known different speaker, or an audio gap.
        let originalGroups = groups
        for index in groups.indices where originalGroups[index].2 == nil {
            let run = originalGroups[index]
            guard
                !gaps.contains(where: {
                    $0.source == phrase.source && $0.start < run.1 && $0.end > run.0
                })
            else { continue }
            let before = index > 0 ? originalGroups[index - 1] : precedingEvidence
            let after = index + 1 < originalGroups.count ? originalGroups[index + 1] : nil
            let words = phrase.words.filter {
                let midpoint = ($0.start + $0.end) / 2
                return midpoint >= run.0 && midpoint < run.1
            }
            let singleton =
                words.count == 1
                && words[0].text.trimmingCharacters(in: .whitespacesAndNewlines).count == 1
            // ASR may include a preceding pause in one character's duration.
            // Only matching stable neighbors permit this longer interior bridge.
            let interiorSingleton =
                singleton && run.1 - run.0 <= 1
                && before?.2 != nil && before?.2?.id == after?.2?.id
                && before.map({ $0.1 - $0.0 >= 0.6 }) == true && after.map({ $0.1 - $0.0 >= 0.6 }) == true
            let corroboratedLeadingWord =
                index == 0 && precedingEvidence != nil && words.count == 1
                && run.1 - run.0 <= 1.5 && before?.2?.id == after?.2?.id && before?.2 != nil
                && before.map({ $0.1 - $0.0 >= 0.6 }) == true && after.map({ $0.1 - $0.0 >= 0.6 }) == true
            guard run.1 - run.0 <= 0.35 || interiorSingleton || corroboratedLeadingWord else { continue }
            let evidenceStart = min(run.0, before?.1 ?? run.0)
            guard
                !gaps.contains(where: {
                    $0.source == phrase.source && $0.start < run.1 && $0.end > evidenceStart
                })
            else { continue }
            let candidate: LiveSpeakerIdentity?
            if let before, let after {
                candidate = before.2?.id == after.2?.id ? before.2 : nil
            }
            else {
                candidate = before?.2 ?? after?.2
            }
            guard let candidate,
                before.map({
                    $0.2?.id == candidate.id && run.0 - $0.1 <= (index == 0 && precedingEvidence != nil ? 0.5 : 0.15)
                }) ?? true,
                after.map({ $0.2?.id == candidate.id && $0.0 - run.1 <= 0.15 }) ?? true,
                [before, after].compactMap({ $0 }).contains(where: {
                    $0.2?.id == candidate.id && $0.1 - $0.0 >= 0.6
                }),
                !sourceIntervals.contains(where: {
                    $0.speakerID != candidate.id && $0.start < run.1 && $0.end > evidenceStart
                })
            else { continue }
            groups[index].2 = candidate
        }
        var joined: [(Double, Double, LiveSpeakerIdentity?)] = []
        for group in groups {
            if let previous = joined.last, previous.2?.id == group.2?.id {
                joined[joined.count - 1].1 = group.1
            }
            else {
                joined.append(group)
            }
        }
        if joined.count == 1 { return [apply(joined[0].2, to: phrase)] }
        return joined.enumerated().compactMap { index, group in
            guard var row = phrase.fragment(start: group.0, end: group.1) else { return nil }
            // The leading row keeps its recognition identity as later words arrive.
            if index == 0 { row.id = phrase.id }
            return apply(group.2, to: row)
        }
    }
}

/// Versioned display policy; separate from the benchmark's raw 0.5 threshold.
struct LiveSpeakerActivityFilter {
    static let policy = "hysteresis-55-45-on50ms-off100ms-v1"
    private var active = Array(repeating: false, count: 8)
    private var runs = Array(repeating: 0, count: 8)
    mutating func accept(_ probabilities: [Float]) -> [Bool] {
        precondition(probabilities.count == 8)
        for slot in probabilities.indices {
            let transition = active[slot] ? probabilities[slot] < 0.45 : probabilities[slot] >= 0.55
            runs[slot] = transition ? runs[slot] + 1 : 0
            if runs[slot] >= (active[slot] ? 10 : 5) {
                active[slot].toggle()
                runs[slot] = 0
            }
        }
        return active
    }
}
