import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerObservationCausalTests {
    private func sample(_ id: String, _ start: Double, _ axis: Int, dimensions: Int = 10) -> SpeakerEvidenceSample {
        var vector = [Double](repeating: 0, count: dimensions)
        vector[axis] = 1
        return .init(
            id: id, source: "microphone", localSpeakerID: "reused-channel", start: start, end: start + 3,
            embedding: .init(
                type: .init(
                    modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                    dimension: dimensions, normalization: "unitL2"), values: vector))
    }

    @Test func emptyLibraryCanRepresentMoreThanEightVoices() throws {
        var engine = SpeakerObservationClustering()
        var ids = Set<String>()
        for index in 0..<10 {
            let result = try engine.ingest(sample("speaker-\(index)", Double(index * 5), index))
            guard case .assigned(let id) = result else {
                Issue.record("Orthogonal clean voice remained unresolved")
                return
            }
            ids.insert(id)
        }
        #expect(ids.count == 10)
        #expect(engine.clusters.count == 10)
        let repeated = try engine.ingest(sample("returning", 60, 0))
        #expect(repeated == .assigned(engine.clusters[0].id))
    }

    @Test func delayedEmbeddingUsesArrivalOrderWithoutRevisingEarlierDecision() throws {
        var engine = SpeakerObservationClustering()
        // The newer excerpt finishes extraction first. A slow earlier excerpt
        // arrives later; acoustic end time must not reject a valid callback.
        let first = try engine.ingest(sample("fast-newer", 20, 0))
        let delayed = try engine.ingest(sample("slow-earlier", 0, 0))
        #expect(delayed == first)
        #expect(engine.clusters[0].samples.map(\.id) == ["fast-newer", "slow-earlier"])
        #expect(engine.clusters.count == 1)
    }

    @Test func prefixAssignmentsAreIndependentOfFutureSuffix() throws {
        let prefix = [sample("a", 0, 0), sample("b", 5, 1), sample("a-return", 10, 0)]
        func replay(_ samples: [SpeakerEvidenceSample]) throws -> [SpeakerObservationClustering.Decision] {
            var engine = SpeakerObservationClustering()
            return try samples.map { try engine.ingest($0) }
        }
        let expected = try replay(prefix)
        let first = try replay(prefix + [sample("new-person", 15, 2), sample("late", 1, 3)])
        let second = try replay(prefix + [sample("different-future", 25, 9)])
        #expect(Array(first.prefix(prefix.count)) == expected)
        #expect(Array(second.prefix(prefix.count)) == expected)
    }
}
