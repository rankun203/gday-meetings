import Foundation
import Testing

@testable import GdayMeetings

struct SpeechSpanFeaturePolicyTests {
    @Test func realSpeechFeaturesAreInvariantToPaddingOffsetAndInactiveFramesAreZero() throws {
        let frames = 998
        let active = try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 48_000)
        #expect(active == 298)
        let original = (0..<(80 * frames)).map { index in
            index % frames < active ? Double(index % 7) : -50
        }
        let shifted = original.enumerated().map { index, value in value + Double(index / frames) + 20 }
        let first = try SpeechSpanFeaturePolicy.centered(original, sampleCount: 48_000)
        let second = try SpeechSpanFeaturePolicy.centered(shifted, sampleCount: 48_000)
        #expect(zip(first, second).allSatisfy { abs($0 - $1) < 1e-12 })
        for bin in 0..<80 {
            #expect(abs(first[(bin * frames)..<(bin * frames + active)].reduce(0, +)) < 1e-9)
            #expect(first[(bin * frames + active)..<((bin + 1) * frames)].allSatisfy { $0 == 0 })
        }
    }

    @Test func exactFrameGeometryAndInvalidInputs() throws {
        #expect(try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 32_000) == 198)
        #expect(try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 160_000) == 998)
        #expect(try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 48_159) == 299)
        #expect(throws: (any Error).self) { try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 31_999) }
        #expect(throws: (any Error).self) { try SpeechSpanFeaturePolicy.activeFrameCount(sampleCount: 160_001) }
        #expect(throws: (any Error).self) { try SpeechSpanFeaturePolicy.centered([0], sampleCount: 48_000) }
        var malformed = [Double](repeating: 0, count: 80 * 998)
        malformed[900] = .nan
        #expect(throws: (any Error).self) { try SpeechSpanFeaturePolicy.centered(malformed, sampleCount: 48_000) }
    }

    @Test func correctedCompatibilityDoesNotRelabelExistingVectors() throws {
        let old = TypedVoiceEmbedding(type: .community1, values: [1] + [Double](repeating: 0, count: 255))
        let roundTrip = try JSONDecoder().decode(TypedVoiceEmbedding.self, from: JSONEncoder().encode(old))
        #expect(roundTrip.type == .community1)
        #expect(roundTrip.type != CommunityVoiceEmbeddingExtractor.embeddingType)
        #expect(CommunityVoiceEmbeddingExtractor.embeddingType == .community1SpeechSpan)
        let worker = TypedVoiceEmbedding(
            type: .unknownLegacy(dimension: 256), values: old.values, provenance: "runpod:synthetic")
        #expect(worker.type == .community1)
        #expect(worker.type != .community1SpeechSpan)
    }
}
