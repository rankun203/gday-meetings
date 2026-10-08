import Foundation

/// Selects a bounded, diverse set from confirmed evidence. Call once per compatible
/// model and person; this never changes the durable sample-to-person decisions.
enum VoiceProfileSelection {
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
        var remaining = Array(candidates.indices).filter { $0 != first }
        // Cache distance to the nearest selected example. Adding an exemplar
        // needs only one new dot product per candidate, preserving the original
        // farthest-first score without recomputing all previous comparisons.
        var closest = [Double?](repeating: nil, count: candidates.count)
        let qualities = candidates.map(quality)
        var newest = first
        while chosen.count < limit, !remaining.isEmpty {
            try cancellationCheck()
            for index in remaining {
                if index % 64 == 0 { try cancellationCheck() }
                guard candidates[index].model == candidates[newest].model,
                    vectors[index].count == vectors[newest].count
                else { continue }
                let similarity = VoiceEmbeddingMath.dot(vectors[index], vectors[newest])
                closest[index] = closest[index].map { max($0, similarity) } ?? similarity
            }
            let next = remaining.max { lhs, rhs in
                let left = 1 - (closest[lhs] ?? -1) + 0.1 * qualities[lhs]
                let right = 1 - (closest[rhs] ?? -1) + 0.1 * qualities[rhs]
                return left == right ? lhs > rhs : left < right
            }!
            chosen.append(next)
            remaining.removeAll { $0 == next }
            newest = next
        }
        return chosen.map { candidates[$0] }
    }
}
