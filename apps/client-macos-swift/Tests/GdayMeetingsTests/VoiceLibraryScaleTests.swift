import Foundation
import Testing

@testable import GdayMeetings

struct VoiceLibraryScaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_PROFILE_SCALE"] == "1"))
    @MainActor func measuredProfileHydrationAndSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let people = (0..<8).map { Person(name: "Person \($0 + 1)") }
        let meeting = UUID()
        let examples = (0..<8_000).map { index in
            var vector = Array(repeating: 0.0, count: 256)
            vector[index % 16] = 1
            return VoiceExample(
                meetingID: meeting, speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
                audioRevision: "synthetic-one", start: Double(index * 4), end: Double(index * 4 + 3),
                personID: people[index % people.count].id, review: .confirmed,
                embeddings: [.init(type: .community1SpeechSpan, values: vector)])
        }
        #expect(library.upsert(examples))
        library.releaseRepresentations()
        // Measure the production path, including representation reads, selection,
        // and release. Bulk persistence and metadata construction are excluded.
        let clock = ContinuousClock()
        var lastHeartbeat = clock.now
        var heartbeatCount = 0
        var maximumHeartbeatGap = Duration.zero
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                maximumHeartbeatGap = max(maximumHeartbeatGap, lastHeartbeat.duration(to: now))
                lastHeartbeat = now
                heartbeatCount += 1
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        let start = clock.now
        let matched = (try await library.matchingPeople(from: people))
        let end = clock.now
        maximumHeartbeatGap = max(maximumHeartbeatGap, lastHeartbeat.duration(to: end))
        heartbeat.cancel()
        let elapsed = start.duration(to: end).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let gap = maximumHeartbeatGap.components
        let gapSeconds = Double(gap.seconds) + Double(gap.attoseconds) / 1e18
        #expect(heartbeatCount > 0)
        #expect(matched.count == people.count)
        #expect(matched.allSatisfy { $0.voiceSamples.count == 12 })
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        let result: [String: Any] = [
            "schemaVersion": 2,
            "workload": "confirmed-profile-hydration-and-selection",
            "exampleCount": examples.count,
            "personCount": people.count,
            "modelCount": 1,
            "embeddingDimension": 256,
            "profileBudgetPerPersonPerModel": 12,
            "selectedCounts": matched.map { $0.voiceSamples.count },
            "elapsedSeconds": seconds,
            "mainActorHeartbeatCount": heartbeatCount,
            "mainActorMaximumHeartbeatGapSeconds": gapSeconds,
            "heartbeatIntervalSeconds": 0.01,
            "includesRepresentationReads": true,
            "includesSetup": false,
            "cacheState": "application-representations-released-filesystem-cache-unspecified",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("GDAY_PROFILE_SCALE_RESULT \(String(decoding: data, as: UTF8.self))")
    }
}
