import Foundation
import Testing

@testable import GdayMeetings

struct VoiceLibraryScaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_PROFILE_SCALE"] == "1"))
    @MainActor func measuredProfileHydrationAndSelection() throws {
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
        let start = clock.now
        let matched = library.matchingPeople(from: people)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        #expect(matched.count == people.count)
        #expect(matched.allSatisfy { $0.voiceSamples.count == 12 })
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        let result: [String: Any] = [
            "schemaVersion": 1,
            "workload": "confirmed-profile-hydration-and-selection",
            "exampleCount": examples.count,
            "personCount": people.count,
            "modelCount": 1,
            "embeddingDimension": 256,
            "profileBudgetPerPersonPerModel": 12,
            "selectedCounts": matched.map { $0.voiceSamples.count },
            "elapsedSeconds": seconds,
            "includesRepresentationReads": true,
            "includesSetup": false,
            "cacheState": "application-representations-released-filesystem-cache-unspecified",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("GDAY_PROFILE_SCALE_RESULT \(String(decoding: data, as: UTF8.self))")
    }
}
