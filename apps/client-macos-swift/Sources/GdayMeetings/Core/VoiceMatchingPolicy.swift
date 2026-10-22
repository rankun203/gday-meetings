import Foundation

/// Cosine similarity policy, scoped to a provider. Scores are not probabilities.
struct VoiceMatchingPolicy: Codable, Equatable, Hashable, Sendable {
    var suggestionThreshold: Double = 0.55
    var automaticThreshold: Double = 0.80
    var minimumMargin: Double = 0.08
    static let `default` = Self()

    var normalized: Self {
        let automatic =
            automaticThreshold.isFinite ? min(1, max(0, automaticThreshold)) : Self.default.automaticThreshold
        return Self(
            suggestionThreshold: suggestionThreshold.isFinite
                ? min(automatic, max(0, suggestionThreshold)) : min(automatic, 0.55),
            automaticThreshold: automatic,
            minimumMargin: minimumMargin.isFinite ? min(1, max(0, minimumMargin)) : 0.08)
    }
}

/// Nearest-neighbor-chain complete-link clustering avoids transitive similarity chains.
/// Competing clusters, rather than individual members of one cluster, supply the
/// margin. All computed joins remain proposals; explicit review is independent.
enum VoiceAutomaticGrouping {
    static func groups(_ examples: [VoiceExample], policy: VoiceMatchingPolicy = .default) -> [[VoiceExample]] {
        let policy = policy.normalized
        let ordered = examples.sorted { $0.id.uuidString < $1.id.uuidString }
        guard ordered.count > 1 else { return ordered.map { [$0] } }
        // Normalize each representation once; pair scoring allocates no vectors.
        let vectors = ordered.map { example in
            example.embeddings.filter(\.isValid).map { embedding in
                let scale = embedding.values.map(abs).max()!
                let scaled = embedding.values.map { $0 / scale }
                let norm = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
                return (embedding.type, scaled.map { $0 / norm })
            }
        }
        let count = ordered.count
        func offset(_ a: Int, _ b: Int) -> Int { a * count - a * (a + 1) / 2 + b - a - 1 }
        func rawSimilarity(_ a: Int, _ b: Int) -> Double {
            var similarity = -1.0
            for (type, left) in vectors[a] {
                for (otherType, right) in vectors[b] where type == otherType {
                    var dot = 0.0
                    for index in left.indices { dot += left[index] * right[index] }
                    similarity = max(similarity, min(1, max(-1, dot)))
                }
            }
            return similarity
        }
        let pairCount = count * (count - 1) / 2
        var distances = Array(repeating: -1.0, count: pairCount)
        for a in ordered.indices {
            if Task.isCancelled { return [] }
            for b in (a + 1)..<ordered.count { distances[offset(a, b)] = rawSimilarity(a, b) }
        }
        // The linkage pass overwrites only cluster representatives' cells. A
        // bitset identifies those cells so margin checks can recompute their
        // original Double scores rather than retain a second full matrix or
        // quantize threshold decisions to Float.
        var overwritten = Array(repeating: UInt64(0), count: (pairCount + 63) / 64)
        // Complete-link nearest-neighbor chains use the weakest cross-cluster
        // pair; ties prefer the previous node, then stable UUID order.
        // See SciPy linkage algorithm notes.
        var active = Array(repeating: true, count: count)
        var members = ordered.indices.map { [$0] }
        var chain: [Int] = []
        var remaining = count
        while remaining > 0 {
            if Task.isCancelled { return [] }
            if chain.isEmpty, let first = active.firstIndex(of: true) { chain.append(first) }
            guard let current = chain.last else { break }
            let previous = chain.count > 1 ? chain[chain.count - 2] : nil
            var nearest = previous
            var strongest = previous.map { distances[offset(min(current, $0), max(current, $0))] } ?? -2
            for other in ordered.indices where active[other] && other != current {
                let similarity = distances[offset(min(current, other), max(current, other))]
                if similarity > strongest {
                    strongest = similarity
                    nearest = other
                }
            }
            guard let nearest, strongest >= policy.automaticThreshold else {
                // All future complete-link similarities can only decrease, so
                // this cluster can no longer join any unfinished cluster.
                active[current] = false
                remaining -= 1
                chain.removeAll(keepingCapacity: true)
                continue
            }
            guard nearest == previous else {
                chain.append(nearest)
                continue
            }
            chain.removeLast(2)
            let keep = min(current, nearest)
            let remove = max(current, nearest)
            members[keep] += members[remove]
            members[remove] = []
            active[remove] = false
            remaining -= 1
            for other in ordered.indices where active[other] && other != keep {
                let destination = offset(min(keep, other), max(keep, other))
                let similarity = min(distances[destination], distances[offset(min(remove, other), max(remove, other))])
                if similarity != distances[destination] {
                    distances[destination] = similarity
                    overwritten[destination >> 6] |= UInt64(1) << (destination & 63)
                }
            }
        }
        var owners = Array(repeating: 0, count: count)
        for (owner, indices) in members.enumerated() {
            for member in indices { owners[member] = owner }
        }
        let clusters = members.filter { !$0.isEmpty }.sorted { $0.min()! < $1.min()! }
        // A single complete-link cluster has no alternative. With the supported
        // margin range it always passes; singleton clusters need no margin test.
        if clusters.count == 1 { return [clusters[0].map { ordered[$0] }] }
        var weakest = Array(repeating: 1.0, count: count)
        var competitor = Array(repeating: -1.0, count: count)
        for a in ordered.indices {
            if Task.isCancelled { return [] }
            for b in (a + 1)..<ordered.count {
                guard members[owners[a]].count > 1 || members[owners[b]].count > 1 else { continue }
                let index = offset(a, b)
                let changed = overwritten[index >> 6] & (UInt64(1) << (index & 63)) != 0
                let score = changed ? rawSimilarity(a, b) : distances[index]
                if owners[a] == owners[b] {
                    weakest[a] = min(weakest[a], score)
                    weakest[b] = min(weakest[b], score)
                }
                else {
                    competitor[a] = max(competitor[a], score)
                    competitor[b] = max(competitor[b], score)
                }
            }
        }
        var result: [[VoiceExample]] = []
        for indices in clusters {
            guard indices.count > 1 else {
                result.append(indices.map { ordered[$0] })
                continue
            }
            // Competitors are independent complete-link clusters before this
            // deferral step. An ambiguous member may still belong to this core;
            // separating its review question does not establish a new identity.
            let confident = indices.filter { weakest[$0] - competitor[$0] >= policy.minimumMargin }
            if !confident.isEmpty { result.append(confident.map { ordered[$0] }) }
            let retained = Set(confident)
            result.append(contentsOf: indices.filter { !retained.contains($0) }.map { [ordered[$0]] })
        }
        return result
    }
}
