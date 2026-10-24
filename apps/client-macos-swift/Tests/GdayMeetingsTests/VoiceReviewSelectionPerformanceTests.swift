import Darwin
import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in workload checks selection cost without audio inference or filesystem fixtures.
struct VoiceReviewSelectionPerformanceTests {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value + 1))!
    }

    private func fixture() -> (examples: [VoiceExample], people: Set<UUID>) {
        let model = EmbeddingType(
            modelID: "synthetic-review-benchmark", revision: "1", compatibilityVersion: "1", dimension: 192,
            normalization: "unitL2")
        let people = Set((0..<10).map { id(10000 + $0) })
        var examples: [VoiceExample] = []
        for index in 0..<3120 {
            let person = index % 10
            let confirmed = index < 120
            var values = [Double](repeating: 0, count: model.dimension)
            values[person] = confirmed ? sqrt(1 - 0.02 * 0.02) : 0.70
            values[confirmed ? 10 + index / 10 : 22 + index % 170] = confirmed ? 0.02 : sqrt(1 - 0.70 * 0.70)
            let start = Double(index * 5)
            examples.append(
                .init(
                    id: id(index), meetingID: id(20000 + index / 10 % 20), speakerID: id(30000 + index % 10),
                    source: index / 10 % 2 == 0 ? "microphone" : "system", audioFile: "audio.wav",
                    audioRevision: "synthetic", start: start, end: start + 3,
                    personID: confirmed ? id(10000 + person) : nil,
                    review: confirmed ? .confirmed : .unassigned,
                    embeddings: [.init(type: model, values: values)],
                    attributionTurn: confirmed ? nil : .init(start: start, end: start + 3)))
        }
        return (examples, people)
    }

    private func usage() -> rusage {
        var value = rusage()
        _ = getrusage(RUSAGE_SELF, &value)
        return value
    }

    private func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_REVIEW_SELECTION_BENCHMARK"] == "1"))
    func selectionRemainsBoundedForThreeThousandUsableTurns() throws {
        let input = fixture()
        #expect(input.examples.count == 3120)
        #expect(input.examples.filter { $0.review == .confirmed }.count == 120)
        let before = usage()
        let started = ContinuousClock.now
        let result = VoiceReviewSelection.evaluate(input.examples, for: input.people)
        let elapsed = started.duration(to: .now).components
        let after = usage()
        #expect(result.candidates.count == 10)
        #expect(result.candidates.values.allSatisfy { !$0.isEmpty && $0.count <= 48 })
        #expect(result.candidates.values.flatMap { $0 }.allSatisfy { $0.review == .unassigned })
        #expect(input.examples.filter { $0.review == .confirmed }.count == 120)
        let metadata = input.examples.map { example in
            var value = example
            value.embeddings = []
            return value
        }
        let playableIDs = Set(input.examples.map(\.id))
        let snapshotBefore = usage()
        let snapshotStarted = ContinuousClock.now
        let snapshot = VoiceReviewSnapshot.make(
            hydrated: input.examples, metadata: metadata, playableIDs: playableIDs,
            personIDs: input.people, revision: 1)
        let snapshotElapsed = snapshotStarted.duration(to: .now).components
        let snapshotAfter = usage()
        #expect(snapshot.candidates.mapValues { $0.map(\.id) } == result.candidates.mapValues { $0.map(\.id) })
        #expect(snapshot.unnamedGroups.allSatisfy { !$0.examples.isEmpty })
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        let report: [String: Any] = [
            "configuration": configuration,
            "turns": 3000, "references": 120, "people": 10, "meetings": 20, "dimensions": 192,
            "selected_questions": result.candidates.values.reduce(0) { $0 + $1.count },
            "selection_seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "user_cpu_seconds": seconds(after.ru_utime) - seconds(before.ru_utime),
            "system_cpu_seconds": seconds(after.ru_stime) - seconds(before.ru_stime),
            "snapshot_seconds": Double(snapshotElapsed.seconds) + Double(snapshotElapsed.attoseconds) / 1e18,
            "snapshot_user_cpu_seconds": seconds(snapshotAfter.ru_utime) - seconds(snapshotBefore.ru_utime),
            "snapshot_system_cpu_seconds": seconds(snapshotAfter.ru_stime) - seconds(snapshotBefore.ru_stime),
            "snapshot_unnamed_groups": snapshot.unnamedGroups.count,
            "process_peak_rss_bytes": snapshotAfter.ru_maxrss,
            "peak_rss_before_selection_bytes": before.ru_maxrss,
        ]
        print(
            "VOICE_REVIEW_SELECTION_BENCHMARK "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        )
    }
}
