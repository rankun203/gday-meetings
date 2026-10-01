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
    func attributing(_ phrase: LiveTranscriptPhrase) -> [LiveTranscriptPhrase] {
        let ids = Set(speakers.filter { $0.source == phrase.source }.map(\.id))
        let relevant = intervals.filter { ids.contains($0.speakerID) && $0.start < phrase.end && $0.end > phrase.start }
        guard !relevant.isEmpty else { return [phrase] }
        func identity(_ start: Double, _ end: Double) -> LiveSpeakerIdentity? {
            let duration = end - start
            guard duration > 0 else { return nil }
            var coverage: [UUID: Double] = [:]
            for interval in relevant {
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
            return row
        }
        guard phrase.hasCompleteWordTiming else { return [apply(identity(phrase.start, phrase.end), to: phrase)] }
        var groups: [(Double, Double, LiveSpeakerIdentity?)] = []
        for word in phrase.words {
            let speaker = identity(word.start, word.end)
            if let last = groups.last, last.2?.id == speaker?.id {
                groups[groups.count - 1].1 = word.end
            }
            else {
                groups.append((word.start, word.end, speaker))
            }
        }
        if groups.count == 1 { return [apply(groups[0].2, to: phrase)] }
        return groups.compactMap { start, end, speaker in
            phrase.fragment(start: start, end: end).map { apply(speaker, to: $0) }
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
