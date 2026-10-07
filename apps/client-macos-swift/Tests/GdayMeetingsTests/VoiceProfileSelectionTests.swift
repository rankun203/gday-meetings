import Foundation
import Testing

@testable import GdayMeetings

struct VoiceProfileSelectionTests {
    private func sample(_ id: String, _ label: String, _ start: Double, _ vector: [Double]) -> SpeakerEvidenceSample {
        let type = EmbeddingType(
            modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: vector.count,
            normalization: "unitL2")
        return .init(
            id: id, source: "microphone", localSpeakerID: label, start: start, end: start + 3,
            embedding: TypedVoiceEmbedding.normalizing(type: type, values: vector)!)
    }

    @Test func profileBudgetIncludesDifferentVoiceConditionsAndIsDeterministic() {
        let samples =
            (0..<20).map { sample(String(format: "%02d", $0), "one", Double($0 * 5), [1, 0]) }
            + [sample("different", "two", 200, [0, 1])]
        let selected = VoiceProfileSelection.select(samples, limit: 12)
        #expect(selected.count == 12)
        #expect(selected.contains { $0.id == "different" })
        #expect(VoiceProfileSelection.select(samples.reversed(), limit: 12) == selected)
        #expect(VoiceProfileSelection.select(samples, limit: 0).isEmpty)
    }
}
