import Foundation

/// Compile alongside the production core and a renamed baseline implementation.
/// Synthetic documents exercise exact output equivalence, not model accuracy.
@main struct CompareImplementations {
    static func document(seed: Int) -> SpeakerEvidenceDocument {
        let model = EmbeddingType(
            modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: 2, normalization: "unitL2")
        var result = SpeakerEvidenceDocument()
        for generation in 0..<(2 + seed % 5) {
            let origin = Double(generation * 30)
            let source = generation % 2 == 0 ? "microphone" : "system"
            let labels = (0..<8).map { "label-\(generation)-\($0)" }
            let capacity = (seed + generation) % 3 == 0 ? origin + 22 : nil
            let window = SpeakerEvidenceWindow(
                generation: "generation-\(generation)", source: source, localSpeakerIDs: labels,
                publicationStart: origin, observedEnd: origin + 30, capacityReachedAt: capacity,
                policyRevision: SpeakerEvidenceWindow.protectedPolicy)
            result.windows = (result.windows ?? []) + [window]
            for slot in 0..<8 {
                for sampleIndex in 0..<4 {
                    let angle = Double((slot + seed + sampleIndex % 2) % 5) * 0.4
                    var embedding = TypedVoiceEmbedding.normalizing(type: model, values: [cos(angle), sin(angle)])!
                    if seed % 11 == 0 && slot == 0 && sampleIndex == 0 { embedding.type.revision = "2" }
                    let start = origin + Double(slot) * 0.25 + Double(sampleIndex * 7)
                    result.samples.append(
                        .init(
                            id: "sample-\(generation)-\(slot)-\(sampleIndex)", source: source,
                            localSpeakerID: labels[slot], start: start, end: start + 3,
                            embedding: embedding, quality: Double((sampleIndex + seed) % 4) / 3))
                    result.activity.append(
                        .init(
                            source: source, localSpeakerID: labels[slot], start: start + 0.5, end: start + 4))
                    if sampleIndex == 0 {
                        result.activity.append(
                            .init(
                                source: source, localSpeakerID: labels[slot], start: start + 1, end: start + 2))
                    }
                }
            }
            result.activity.append(
                .init(source: source, localSpeakerID: "unknown-\(generation)", start: origin, end: origin + 1))
        }
        if seed % 2 == 0 {
            result.samples.reverse()
            result.activity.reverse()
        }
        return result
    }

    static func main() throws {
        var checks = 0
        for seed in 0..<64 {
            let document = document(seed: seed)
            for threshold in [-0.2, 0.72, 1.0] {
                let before = try SpeakerConsolidationBaseline.run(
                    document, configuration: .init(minimumSimilarity: threshold))
                let after = try SpeakerConsolidation.run(document, configuration: .init(minimumSimilarity: threshold))
                guard before.result == after.result else {
                    fatalError("Changed speaker output: seed \(seed), threshold \(threshold)")
                }
                guard before.audit.cannotLinkUnitPairs == after.audit.cannotLinkUnitPairs,
                    before.audit.untrustedSampleIDs == after.audit.untrustedSampleIDs,
                    abs(before.audit.directSampleSpeakerSeconds - after.audit.directSampleSpeakerSeconds) < 1e-9,
                    abs(before.audit.channelInferredSpeakerSeconds - after.audit.channelInferredSpeakerSeconds) < 1e-9,
                    abs(before.audit.unresolvedSpeakerSeconds - after.audit.unresolvedSpeakerSeconds) < 1e-9
                else { fatalError("Changed coverage audit: seed \(seed), threshold \(threshold)") }
                checks += 1
            }
        }
        print("Equivalent speaker output and coverage audit across \(checks) synthetic configurations")
    }
}
