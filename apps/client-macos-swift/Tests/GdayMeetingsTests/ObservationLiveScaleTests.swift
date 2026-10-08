import Darwin
import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in resource experiment. Replays recorded model callbacks without rerunning
/// inference; repeats/remaps recording windows to exercise a two-hour session.
struct ObservationLiveScaleTests {
    @MainActor private final class HeartbeatState {
        var phase = "replay idle"
        var audioThrough = 0.0
        var previousPhase = "replay idle"
        var previous = ContinuousClock.now
        var maximum = Duration.zero
        var gaps: [Double] = []
        var count = 0
        var maximumContext: [String: Any] = [:]
        func record(countTick: Bool = true) {
            let now = ContinuousClock.now
            let gap = previous.duration(to: now)
            let components = gap.components
            gaps.append(Double(components.seconds) + Double(components.attoseconds) / 1e18)
            if gap > maximum {
                maximum = gap
                maximumContext = ["audioSeconds": audioThrough, "previousPhase": previousPhase, "phase": phase]
            }
            previous = now
            previousPhase = phase
            if countTick { count += 1 }
        }
    }

    struct Trace: Decodable {
        struct Entry: Decodable {
            var audioSubmittedThrough: Double
            var kind: String
            var sampleID: String?
            var event: LiveSpeakerEvent?
        }
        var entries: [Entry]
    }
    private func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private func peakRSS() -> Int64 {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Int64(value.ru_maxrss)
    }
    private func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        return [
            "count": Double(sorted.count), "p50Seconds": sorted[sorted.count / 2],
            "p95Seconds": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "maximumSeconds": sorted.last!, "totalSeconds": sorted.reduce(0, +),
        ]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_OBSERVATION_SCALE_INPUT"] != nil))
    @MainActor func recordedTwoHourIdentityAndPeopleResourceProfile() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(env["GDAY_OBSERVATION_SCALE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(env["GDAY_OBSERVATION_SCALE_OUTPUT"]))
        let duration = Double(env["GDAY_OBSERVATION_SCALE_SECONDS"] ?? "7200") ?? 7200
        let existingCount = Int(env["GDAY_OBSERVATION_SCALE_EXAMPLES"] ?? "8000") ?? 8000
        let evidence = try JSONDecoder().decode(
            SpeakerEvidenceDocument.self,
            from: Data(contentsOf: input.appendingPathComponent("evidence.json")))
        let trace = try JSONDecoder().decode(
            Trace.self,
            from: Data(contentsOf: input.appendingPathComponent("availability.json")))
        let samples = Dictionary(uniqueKeysWithValues: evidence.samples.map { ($0.id, $0) })
        let sourceDuration = try #require(trace.entries.last?.audioSubmittedThrough)
        try #require(!samples.isEmpty && sourceDuration > 0 && duration > 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let people = (0..<16).map { Person(name: "Scale profile \($0)") }
        let priorMeeting = UUID()
        let sortedSamples = evidence.samples.sorted { $0.id < $1.id }
        let setupStarted = ContinuousClock.now
        var existing: [VoiceExample] = (0..<existingCount).map { index in
            .init(
                meetingID: priorMeeting, speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
                audioRevision: "scale-fixture", start: Double(index * 4), end: Double(index * 4 + 3),
                personID: people[index % people.count].id, review: .confirmed,
                embeddings: [sortedSamples[index % sortedSamples.count].embedding])
        }
        #expect(library.upsert(existing))
        existing.removeAll()
        library.releaseRepresentations()
        let setupSeconds = seconds(setupStarted.duration(to: .now))
        print("GDAY_SCALE_STAGE setup complete: \(setupSeconds)s, \(existingCount) examples")
        let baselineRSS = peakRSS()
        let meeting = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var adapter = LiveObservationIdentity(meetingID: meeting)
        let worker = LiveObservationIdentityWorker(configuration: .init())
        var projected: LiveSpeakerTimeline?
        var admissionTimes: [Double] = []
        var applyTimes: [Double] = []
        var engineTimes: [Double] = []
        var projectionTimes: [Double] = []
        var reconciliationTimes: [Double] = []
        var checkpoints: [[String: Any]] = []
        var callbacks = 0
        var admitted = 0
        var callbackCycles = 0
        var lastCheckpoint = 0.0
        var activeClusterIDs = Set<UUID>()
        let clock = ContinuousClock()
        let heartbeatState = HeartbeatState()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
                heartbeatState.record()
            }
        }
        defer { heartbeat.cancel() }
        let started = clock.now
        var cycle = 0
        while Double(cycle) * sourceDuration < duration {
            let offset = Double(cycle) * sourceDuration
            func remap(_ id: UUID) -> UUID {
                MeetingSpeakerConsolidation.identity(
                    meetingID: meeting,
                    clusterID: "\(cycle):\(id.uuidString)", method: "resource-replay-window-v1")
            }
            for entry in trace.entries {
                let through = offset + entry.audioSubmittedThrough
                if through > duration { break }
                callbacks += 1
                heartbeatState.audioThrough = through
                if var event = entry.event, entry.kind == "speakerEvent" {
                    event.generation = remap(event.generation)
                    event.start += offset
                    event.end += offset
                    event.speakers = event.speakers.map { value in
                        var value = value
                        value.id = remap(value.id)
                        value.generation = remap(value.generation)
                        return value
                    }
                    event.intervals = event.intervals.map { value in
                        var value = value
                        value.speakerID = remap(value.speakerID)
                        value.start += offset
                        value.end += offset
                        return value
                    }
                    if var window = event.continuity {
                        window.generation = event.generation.uuidString
                        window.localSpeakerIDs = window.localSpeakerIDs.map { remap(UUID(uuidString: $0)!).uuidString }
                        window.publicationStart += offset
                        window.observedEnd += offset
                        window.capacityReachedAt = window.capacityReachedAt.map { $0 + offset }
                        event.continuity = window
                    }
                    let admittedAt = clock.now
                    let accepted = adapter.accept(event)
                    admissionTimes.append(seconds(admittedAt.duration(to: clock.now)))
                    try #require(accepted)
                }
                else if entry.kind == "embeddingReady", let id = entry.sampleID, var sample = samples[id] {
                    sample.id = "\(cycle):\(sample.id)"
                    sample.localSpeakerID = remap(UUID(uuidString: sample.localSpeakerID)!).uuidString
                    sample.start += offset
                    sample.end += offset
                    let admittedAt = clock.now
                    adapter.accept(sample)
                    admissionTimes.append(seconds(admittedAt.duration(to: clock.now)))
                }
                let ready = adapter.takeReady()
                admitted += ready.count
                if !ready.isEmpty {
                    heartbeatState.phase = "identity worker"
                    let began = clock.now
                    let result = try await worker.ingest(
                        ready, activity: adapter.trustedActivity(),
                        untrustedActivity: adapter.untrustedActivity(),
                        untrustedSampleIDs: adapter.untrustedSampleIDs(ready))
                    engineTimes.append(seconds(began.duration(to: clock.now)))
                    heartbeatState.phase = "identity update application"
                    let applyStarted = clock.now
                    adapter.apply(result)
                    applyTimes.append(seconds(applyStarted.duration(to: clock.now)))
                    activeClusterIDs = Set(
                        result.clusters.map {
                            MeetingSpeakerConsolidation.identity(
                                meetingID: meeting, clusterID: $0.id,
                                method: "live-observation-identity-v1")
                        })
                    let representatives = result.clusters.flatMap { cluster in
                        let speaker = MeetingSpeakerConsolidation.identity(
                            meetingID: meeting, clusterID: cluster.id,
                            method: "live-observation-identity-v1")
                        return cluster.prototypes.map { sample in
                            VoiceExample(
                                id: MeetingSpeakerConsolidation.identity(
                                    meetingID: meeting, clusterID: sample.id,
                                    method: "live-observation-evidence-v1"),
                                meetingID: meeting, speakerID: speaker, source: sample.source,
                                audioFile: "microphone.wav", start: sample.start, end: sample.end,
                                embeddings: [sample.embedding], groupID: speaker, origin: .liveSpeech,
                                observationID: sample.id)
                        }
                    }
                    heartbeatState.phase = "representative reconciliation"
                    let reconcileStarted = clock.now
                    #expect(
                        await library.reconcileObservationExamplesForCapture(
                            meetingID: meeting, representatives: representatives))
                    reconciliationTimes.append(seconds(reconcileStarted.duration(to: clock.now)))
                    heartbeatState.phase = "schedule People matching"
                    library.scheduleReviewedPeopleSuggestions(from: people)
                }
                heartbeatState.phase = "timeline projection"
                let projectionStarted = clock.now
                projected = adapter.projection(preserving: projected)
                projectionTimes.append(seconds(projectionStarted.duration(to: clock.now)))
                if through - lastCheckpoint >= 1800 {
                    let identities = projected!.speakers
                    checkpoints.append([
                        "audioSeconds": through, "peakRSSBytes": peakRSS(),
                        "speakerMetadataCount": identities.count, "activeClusters": activeClusterIDs.count,
                        "identityVectorCount": identities.filter { $0.voiceEmbedding != nil }.count,
                        "retiredIdentityVectorCount": identities.filter {
                            $0.voiceEmbedding != nil && !activeClusterIDs.contains($0.id)
                        }.count, "libraryExampleCount": library.examples.count,
                    ])
                    print("GDAY_SCALE_STAGE replay audio \(through)s, callbacks \(callbacks), embeddings \(admitted)")
                    lastCheckpoint = through
                }
                heartbeatState.phase = "callback yield"
                await Task.yield()
            }
            cycle += 1
            callbackCycles += 1
        }
        let replayElapsed = seconds(started.duration(to: clock.now))
        print("GDAY_SCALE_STAGE replay complete: \(replayElapsed)s; final matching begins")
        heartbeatState.phase = "final People matching"
        let finalMatchingStarted = clock.now
        await library.suggestReviewedPeople(from: people)
        let finalMatchingSeconds = seconds(finalMatchingStarted.duration(to: clock.now))
        heartbeatState.record(countTick: false)
        heartbeat.cancel()
        let identities = projected?.speakers ?? []
        let result: [String: Any] = [
            "schemaVersion": 2, "capacityIngestion": "trusted-and-direct-untrusted-v6",
            "workload": "recorded-callbacks-repeated-with-remapped-local-windows",
            "sourceAudioSeconds": sourceDuration, "simulatedAudioSeconds": heartbeatState.audioThrough,
            "recordingCycles": callbackCycles, "callbackCount": callbacks, "admittedEmbeddings": admitted,
            "existingPeople": people.count, "existingExamples": existingCount,
            "setupSecondsExcluded": setupSeconds, "replayWallSeconds": replayElapsed,
            "admission": summary(admissionTimes), "identityUpdateApplication": summary(applyTimes),
            "projection": summary(projectionTimes), "identityWorker": summary(engineTimes),
            "representativeReconciliation": summary(reconciliationTimes),
            "finalMatchingSeconds": finalMatchingSeconds,
            "mainActorHeartbeatCount": heartbeatState.count,
            "mainActorHeartbeatGaps": summary(heartbeatState.gaps),
            "maximumHeartbeatGapContext": heartbeatState.maximumContext,
            "concurrentLoad": env["GDAY_OBSERVATION_SCALE_LOAD_NOTE"] ?? "not controlled",
            "mainActorMaximumHeartbeatGapSeconds": seconds(heartbeatState.maximum),
            "postSetupPeakRSSBytes": baselineRSS, "finalPeakRSSBytes": peakRSS(),
            "peakRSSGrowthBytes": max(0, peakRSS() - baselineRSS), "checkpoints": checkpoints,
            "speakerMetadataCount": identities.count, "activeClusters": activeClusterIDs.count,
            "identityVectorCount": identities.filter { $0.voiceEmbedding != nil }.count,
            "retiredIdentityVectorCount": identities.filter {
                $0.voiceEmbedding != nil && !activeClusterIDs.contains($0.id)
            }.count,
            "limitations": [
                "No audio model inference or UI rendering", "Unpaced replay with main-actor yield after each callback",
                "Repeated recorded voices are not new independent meetings",
                "Peak RSS includes test process and matching caches",
                "Existing People assignments are storage-load fixtures, not identity ground truth",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .withoutOverwriting)
        print("GDAY_OBSERVATION_SCALE_RESULT \(String(decoding: data, as: UTF8.self))")
        #expect(admitted > 0 && callbacks > 0)
    }
}
