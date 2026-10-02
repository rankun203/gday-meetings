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

struct LiveSpeakerTimeline: Codable, Equatable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
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

    /// Timed words use exclusive observed speaker activity. Untimed phrases
    /// require majority coverage and never invent a new word boundary.
    func attributing(_ phrase: LiveTranscriptPhrase, preceding: LiveTranscriptPhrase? = nil) -> [LiveTranscriptPhrase] {
        let ids = Set(speakers.filter { $0.source == phrase.source }.map(\.id))
        let sourceIntervals = intervals.filter { ids.contains($0.speakerID) }
        let relevant = sourceIntervals.filter { $0.start < phrase.end && $0.end > phrase.start }
        func identity(
            _ start: Double, _ end: Double, activity: [LiveSpeakerInterval], timedWord: Bool = false
        ) -> LiveSpeakerIdentity? {
            let duration = end - start
            let tolerance = 0.000_001
            guard duration > 0,
                !gaps.contains(where: { $0.source == phrase.source && $0.start < end && $0.end > start }),
                cursors.first(where: { $0.source == phrase.source }).map({ end <= $0.end + tolerance }) ?? true
            else { return nil }
            var clipped: [UUID: [(Double, Double)]] = [:]
            for interval in activity {
                let lower = max(start, interval.start)
                let upper = min(end, interval.end)
                if upper > lower { clipped[interval.speakerID, default: []].append((lower, upper)) }
            }
            var unions: [UUID: [(Double, Double)]] = [:]
            for (speaker, spans) in clipped {
                var merged: [(Double, Double)] = []
                for span in spans.sorted(by: { $0.0 < $1.0 }) {
                    if let last = merged.last, span.0 <= last.1 {
                        merged[merged.count - 1].1 = max(last.1, span.1)
                    }
                    else {
                        merged.append(span)
                    }
                }
                if merged.reduce(0, { $0 + $1.1 - $1.0 }) > tolerance { unions[speaker] = merged }
            }
            // Unlabeled time is not a vote for another identity. Competing
            // observed identities remain unresolved, including sequential turns.
            guard unions.count == 1, let (speaker, spans) = unions.first else { return nil }
            let observed = spans.reduce(0) { $0 + $1.1 - $1.0 }
            let minimum = timedWord ? min(0.1, duration * 0.6) : duration * 0.6
            guard observed + tolerance >= minimum else { return nil }
            if timedWord, observed + tolerance < duration * 0.6 {
                // A lone head/tail from an adjacent turn cannot claim a long
                // ASR range. Support on both sides can bracket internal silence.
                let centralStart = start + duration * 0.25
                let centralEnd = end - duration * 0.25
                let central = spans.reduce(0) {
                    $0 + max(0, min($1.1, centralEnd) - max($1.0, centralStart))
                }
                let leading = spans.reduce(0) {
                    $0 + max(0, min($1.1, centralStart) - max($1.0, start))
                }
                let trailing = spans.reduce(0) {
                    $0 + max(0, min($1.1, end) - max($1.0, centralEnd))
                }
                let supportMinimum = min(0.01, minimum)
                guard
                    central + tolerance >= supportMinimum
                        || (leading + tolerance >= supportMinimum && trailing + tolerance >= supportMinimum)
                else { return nil }
            }
            return speakers.first { $0.id == speaker }
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
                guard let speaker = identity(word.start, word.end, activity: precedingActivity, timedWord: true) else {
                    break
                }
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
            let speaker = identity(word.start, word.end, activity: relevant, timedWord: true)
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
            guard cursors.first(where: { $0.source == phrase.source }).map({ run.1 <= $0.end + 0.000_001 }) ?? true
            else { continue }
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
            let singleWord = words.count == 1
            // ASR word timing may include a pause with no speaker activity.
            // Only matching stable neighbors permit this longer interior bridge.
            let interiorWord =
                singleWord && run.1 - run.0 <= 1
                && before?.2 != nil && before?.2?.id == after?.2?.id
                && before.map({ $0.1 - $0.0 >= 0.6 }) == true && after.map({ $0.1 - $0.0 >= 0.6 }) == true
            let corroboratedLeadingWord =
                index == 0 && precedingEvidence != nil && words.count == 1
                && run.1 - run.0 <= 1.5 && before?.2?.id == after?.2?.id && before?.2 != nil
                && before.map({ $0.1 - $0.0 >= 0.6 }) == true && after.map({ $0.1 - $0.0 >= 0.6 }) == true
            guard run.1 - run.0 <= 0.35 || interiorWord || corroboratedLeadingWord else { continue }
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

/// An augmented range tree skips nonoverlapping subtrees even when a long
/// interval spans many shorter entries. The index is disposable and keeps no audio.
struct LiveSpeakerIntervalIndex {
    private struct RangeIndex<Value> {
        let values: [Value]
        let maximumEnds: [Double]
        let leafCount: Int
        let start: (Value) -> Double

        init(_ values: [Value], start: @escaping (Value) -> Double, end: (Value) -> Double) {
            self.values = values.sorted { start($0) < start($1) }
            self.start = start
            var count = 1
            while count < values.count { count *= 2 }
            leafCount = count
            var ends = Array(repeating: -Double.infinity, count: count * 2)
            for (index, value) in self.values.enumerated() { ends[count + index] = end(value) }
            if count > 1 {
                for index in stride(from: count - 1, through: 1, by: -1) {
                    ends[index] = max(ends[index * 2], ends[index * 2 + 1])
                }
            }
            maximumEnds = ends
        }

        func overlapping(start lowerBound: Double, end upperBound: Double) -> [Value] {
            var result: [Value] = []
            func visit(_ node: Int, lower: Int, upper: Int) {
                guard lower < values.count, maximumEnds[node] > lowerBound,
                    start(values[lower]) < upperBound
                else { return }
                if upper - lower == 1 {
                    result.append(values[lower])
                    return
                }
                let middle = (lower + upper) / 2
                visit(node * 2, lower: lower, upper: middle)
                visit(node * 2 + 1, lower: middle, upper: upper)
            }
            visit(1, lower: 0, upper: leafCount)
            return result
        }
    }

    private var sources: [LiveAudioSource: RangeIndex<LiveSpeakerInterval>] = [:]
    private var gapsBySource: [LiveAudioSource: RangeIndex<LiveTranscriptGap>] = [:]
    private var speakersBySource: [LiveAudioSource: [LiveSpeakerIdentity]] = [:]
    private var timeline: LiveSpeakerTimeline

    init(_ timeline: LiveSpeakerTimeline) {
        self.timeline = timeline
        gapsBySource = Dictionary(grouping: timeline.gaps, by: \.source).mapValues {
            RangeIndex($0, start: { $0.start }, end: { $0.end })
        }
        speakersBySource = Dictionary(grouping: timeline.speakers, by: \.source)
        let sourcesByID = Dictionary(grouping: timeline.speakers, by: \.id).mapValues { Set($0.map(\.source)) }
        var grouped: [LiveAudioSource: [LiveSpeakerInterval]] = [:]
        for interval in timeline.intervals {
            for source in sourcesByID[interval.speakerID] ?? [] { grouped[source, default: []].append(interval) }
        }
        for (source, values) in grouped {
            sources[source] = RangeIndex(values, start: { $0.start }, end: { $0.end })
        }
    }

    mutating func update(_ timeline: LiveSpeakerTimeline) {
        let sameSources =
            self.timeline.speakers.count == timeline.speakers.count
            && zip(self.timeline.speakers, timeline.speakers).allSatisfy {
                $0.id == $1.id && $0.source == $1.source
            }
        if sameSources, self.timeline.intervals == timeline.intervals {
            if self.timeline.gaps != timeline.gaps {
                gapsBySource = Dictionary(grouping: timeline.gaps, by: \.source).mapValues {
                    RangeIndex($0, start: { $0.start }, end: { $0.end })
                }
            }
            if self.timeline.speakers != timeline.speakers {
                speakersBySource = Dictionary(grouping: timeline.speakers, by: \.source)
            }
            self.timeline = timeline
        }
        else {
            self = Self(timeline)
        }
    }

    func evidence(for phrase: LiveTranscriptPhrase, preceding: LiveTranscriptPhrase?) -> LiveSpeakerTimeline {
        let usesPreceding =
            preceding.map {
                $0.source == phrase.source && $0.session == phrase.session && $0.hasCompleteWordTiming
                    && $0.end <= phrase.start && phrase.start - $0.end <= 0.5
            } ?? false
        let start = usesPreceding ? min(phrase.start, preceding!.start) : phrase.start
        var evidence = LiveSpeakerTimeline()
        evidence.speakers = speakersBySource[phrase.source] ?? []
        evidence.intervals = sources[phrase.source]?.overlapping(start: start, end: phrase.end) ?? []
        evidence.gaps = gapsBySource[phrase.source]?.overlapping(start: start, end: phrase.end) ?? []
        evidence.cursors = timeline.cursors.filter { $0.source == phrase.source }.map {
            // Sequence and finality do not affect attribution. Once coverage has
            // reached this phrase, advancing the live tail cannot change it.
            .init(
                source: $0.source, generation: $0.generation, sequence: 0,
                end: min($0.end, phrase.end), final: false)
        }
        return evidence
    }
}
