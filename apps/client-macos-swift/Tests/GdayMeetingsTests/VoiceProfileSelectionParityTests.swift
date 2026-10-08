import Foundation
import Testing

@testable import GdayMeetings

struct VoiceProfileSelectionParityTests {
    private func sample(_ id: Int, vector: [Double], model: String = "test", duration: Double = 3, quality: Double = 1)
        -> SpeakerEvidenceSample
    {
        .init(
            id: String(format: "%04d", id), source: "microphone", localSpeakerID: "one", start: Double(id * 4),
            end: Double(id * 4) + duration,
            embedding: .normalizing(
                type: .init(
                    modelID: model, revision: "1", compatibilityVersion: "1", dimension: vector.count,
                    normalization: "unitL2"), values: vector)!, quality: quality)
    }
    @Test func cachedDistancesPreservePreviousSelectionAndTieOrder() {
        var state: UInt64 = 9731
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 32) / Double(UInt32.max) * 2 - 1
        }
        var varied: [SpeakerEvidenceSample] = []
        for index in 0..<96 {
            let otherModel = index % 3 == 0
            let dimension: Int = otherModel ? 16 : 8
            let vector: [Double] = (0..<dimension).map { _ in random() }
            let model: String = otherModel ? "other" : "test"
            let duration: Double = Double(index % 5 + 1)
            let quality: Double = Double(index % 7 + 1) / 7.0
            varied.append(sample(index, vector: vector, model: model, duration: duration, quality: quality))
        }
        let ties = (0..<24).map { sample($0, vector: $0 % 2 == 0 ? [1, 0] : [-1, 0]) }
        for values in [varied, ties, Array(varied.reversed()), Array(ties.reversed())] {
            for limit in [0, 1, 2, 3, 12, 32, 110] {
                #expect(
                    VoiceProfileSelection.select(values, limit: limit).map(\.id)
                        == PreviousVoiceProfileSelection.select(values, limit: limit).map(\.id))
            }
        }
    }
    @Test func selectionStillRespondsToCancellation() {
        let values = (0..<128).map { sample($0, vector: [1, Double($0) / 128]) }
        #expect(throws: CancellationError.self) {
            try VoiceProfileSelection.selectCancellable(values, limit: 12) { throw CancellationError() }
        }
    }
}

/// Selects a bounded, diverse set from confirmed evidence. Call once per compatible
/// model and person; this never changes the durable sample-to-person decisions.
private enum PreviousVoiceProfileSelection {
    private static func quality(_ sample: SpeakerEvidenceSample) -> Double {
        let duration = sample.end - sample.start
        let durationScore = duration.isFinite ? min(1, max(0, duration / 3)) : 0
        return min(1, max(0, sample.quality)) * durationScore
    }

    static func select(_ samples: [SpeakerEvidenceSample], limit: Int = 12) -> [SpeakerEvidenceSample] {
        selectCancellable(samples, limit: limit, cancellationCheck: {})
    }

    static func selectCancellable(
        _ samples: [SpeakerEvidenceSample], limit: Int = 12, cancellationCheck: () throws -> Void
    ) rethrows -> [SpeakerEvidenceSample] {
        try cancellationCheck()
        guard limit > 0 else { return [] }
        let candidates = samples.filter { $0.embedding.isValid && $0.quality.isFinite }
            .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else { return [] }
        let vectors = candidates.map { VoiceEmbeddingMath.normalized($0.vector)! }
        // The first example is a quality-weighted medoid, not simply the newest excerpt.
        var sums: [EmbeddingType: [Double]] = [:]
        var counts: [EmbeddingType: Int] = [:]
        for index in candidates.indices {
            if index % 64 == 0 { try cancellationCheck() }
            let model = candidates[index].model
            var sum = sums[model] ?? Array(repeating: 0, count: vectors[index].count)
            for dimension in sum.indices { sum[dimension] += vectors[index][dimension] }
            sums[model] = sum
            counts[model, default: 0] += 1
        }
        let centrality = candidates.indices.map { index in
            VoiceEmbeddingMath.dot(vectors[index], sums[candidates[index].model]!)
                / Double(counts[candidates[index].model]!) + 0.1 * quality(candidates[index])
        }
        let first = candidates.indices.max { lhs, rhs in
            centrality[lhs] == centrality[rhs] ? lhs > rhs : centrality[lhs] < centrality[rhs]
        }!
        var chosen = [first]
        var remaining = Set(candidates.indices).subtracting(chosen)
        while chosen.count < limit, !remaining.isEmpty {
            try cancellationCheck()
            let next = remaining.sorted().max { lhs, rhs in
                func score(_ index: Int) -> Double {
                    let similarities = chosen.filter {
                        candidates[$0].model == candidates[index].model && vectors[$0].count == vectors[index].count
                    }.map { VoiceEmbeddingMath.dot(vectors[index], vectors[$0]) }
                    return 1 - (similarities.max() ?? -1) + 0.1 * quality(candidates[index])
                }
                let left = score(lhs)
                let right = score(rhs)
                return left == right ? lhs > rhs : left < right
            }!
            chosen.append(next)
            remaining.remove(next)
        }
        return chosen.map { candidates[$0] }
    }
}
