import Foundation
import Testing

@testable import GdayMeetings

/// An opt-in integration experiment over recorded model callbacks. Ordinary test
/// runs need no private meeting files. The adapter is the same one capture uses.
struct LiveObservationRecordedReplayTests {
    struct Trace: Decodable {
        struct Entry: Decodable {
            var ordinal: Int
            var audioSubmittedThrough: Double
            var kind: String
            var sampleID: String?
            var event: LiveSpeakerEvent?
        }
        var schemaVersion: Int
        var clock: String
        var entries: [Entry]
    }
    struct Interval: Codable {
        var start: Double
        var end: Double
        var source: String
        var speaker: String
    }
    struct AliasEvent: Encodable {
        var callbackOrdinal: Int
        var availableAt: Double
        var sourceIdentity: String
        var targetIdentity: String
    }
    struct Output: Encodable {
        var clock: String
        var intervals: [Interval]
        var publishedIntervals: [Interval]
        var identityAliases: [String: String]
        var aliasEvents: [AliasEvent]
        var admittedSamples: Int
        var callbackCount: Int
        var configuration: SpeakerObservationClustering.Configuration
    }

    @Test func replayRecordedCallbacksThroughLiveAdapter() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["GDAY_OBSERVATION_REPLAY_INPUT"], let output = env["GDAY_OBSERVATION_REPLAY_OUTPUT"]
        else { return }
        let folder = URL(fileURLWithPath: input)
        let evidence = try JSONDecoder().decode(
            SpeakerEvidenceDocument.self, from: Data(contentsOf: folder.appendingPathComponent("evidence.json")))
        let trace = try JSONDecoder().decode(
            Trace.self, from: Data(contentsOf: folder.appendingPathComponent("availability.json")))
        try #require(trace.schemaVersion == 1 && trace.clock == "submitted-audio-upper-bound")
        let samples = Dictionary(uniqueKeysWithValues: evidence.samples.map { ($0.id, $0) })
        var configuration = SpeakerObservationClustering.Configuration()
        if let policy = env["GDAY_OBSERVATION_REPLAY_POLICY"] {
            configuration = try JSONDecoder().decode(
                SpeakerObservationClustering.Configuration.self,
                from: Data(contentsOf: URL(fileURLWithPath: policy)))
        }
        let worker = LiveObservationIdentityWorker(configuration: configuration)
        var adapter = LiveObservationIdentity(meetingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        var projected: LiveSpeakerTimeline?
        var pendingActivity: [(source: LiveAudioSource, interval: LiveSpeakerInterval)] = []
        var frozenThrough: [LiveAudioSource: Double] = [:]
        var frozen: [Interval] = []
        var aliasEvents: [AliasEvent] = []
        var seenAliases: [UUID: UUID] = [:]
        var admitted = 0
        var previousClock = -Double.infinity
        func publish(source: LiveAudioSource, through end: Double, timeline: LiveSpeakerTimeline) {
            let lower = frozenThrough[source] ?? 0
            guard end > lower else { return }
            let activity = pendingActivity.filter {
                $0.source == source && $0.interval.end > lower && $0.interval.start < end
            }
            for item in activity {
                let start = max(lower, item.interval.start)
                let stop = min(end, item.interval.end)
                let relevant = timeline.intervals.filter {
                    $0.source == source && $0.localTrackID == item.interval.speakerID && $0.end > start
                        && $0.start < stop
                }
                var cuts = [start, stop]
                for interval in relevant { cuts += [max(start, interval.start), min(stop, interval.end)] }
                cuts = Array(Set(cuts)).sorted()
                for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                    let active = Set(relevant.filter { $0.start < b && $0.end > a }.map(\.speakerID))
                    let speaker =
                        active.count == 1
                        ? active.first!.uuidString : "unresolved:\(source.rawValue):\(item.interval.speakerID)"
                    frozen.append(.init(start: a, end: b, source: source.rawValue, speaker: speaker))
                }
            }
            frozenThrough[source] = end
            pendingActivity.removeAll { $0.source == source && $0.interval.end <= end }
        }
        for (index, entry) in trace.entries.enumerated() {
            try #require(entry.ordinal == index && entry.audioSubmittedThrough >= previousClock)
            previousClock = entry.audioSubmittedThrough
            if entry.kind == "speakerEvent" {
                let event = try #require(entry.event)
                let accepted1 = adapter.accept(event)
                try #require(accepted1)
                pendingActivity += event.intervals.map { (event.source, $0) }
            }
            else if entry.kind == "embeddingReady" {
                let id = try #require(entry.sampleID)
                let sample = try #require(samples[id])
                try #require(sample.end <= entry.audioSubmittedThrough)
                adapter.accept(sample)
            }
            else {
                Issue.record("Unsupported callback \(entry.kind)")
                return
            }
            let ready = adapter.takeReady()
            admitted += ready.count
            if !ready.isEmpty {
                adapter.apply(
                    try await worker.ingest(
                        ready, activity: adapter.trustedActivity(), untrustedActivity: adapter.untrustedActivity(),
                        untrustedSampleIDs: adapter.untrustedSampleIDs(ready)))
            }
            projected = adapter.projection(preserving: projected)
            for (source, target) in projected!.identityAliases ?? [:] where seenAliases[source] != target {
                aliasEvents.append(
                    .init(
                        callbackOrdinal: entry.ordinal, availableAt: entry.audioSubmittedThrough,
                        sourceIdentity: source.uuidString, targetIdentity: target.uuidString))
            }
            seenAliases = projected!.identityAliases ?? [:]
            for cursor in projected!.cursors {
                publish(
                    source: cursor.source, through: max(0, cursor.end - LiveObservationIdentity.revisionHorizon),
                    timeline: projected!)
            }
        }
        let final = try #require(projected)
        for cursor in final.cursors { publish(source: cursor.source, through: cursor.end, timeline: final) }
        let canonical = frozen.map { interval -> Interval in
            guard let id = UUID(uuidString: interval.speaker) else { return interval }
            var value = interval
            value.speaker = LiveSpeakerAliases.resolve(id, aliases: final.identityAliases ?? [:]).uuidString
            return value
        }
        let result = Output(
            clock: trace.clock, intervals: canonical, publishedIntervals: frozen,
            identityAliases: Dictionary(
                uniqueKeysWithValues: (final.identityAliases ?? [:]).map { ($0.key.uuidString, $0.value.uuidString) }),
            aliasEvents: aliasEvents, admittedSamples: admitted,
            callbackCount: trace.entries.count, configuration: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
}
