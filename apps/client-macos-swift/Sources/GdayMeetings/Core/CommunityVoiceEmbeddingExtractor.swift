import CoreML
import Foundation

/// Extracts one voice vector from a caller-selected, non-overlapping speech span.
/// This uses the same pinned FBANK/WeSpeaker assets as Community-1, but does not
/// run segmentation or clustering. Keep its model lease alive while using it.
actor CommunityVoiceEmbeddingExtractor {
    static let embeddingType = EmbeddingType.community1SpeechSpan
    private let fbank: MLModel
    private let embedding: MLModel
    private let audioConstraint: MLMultiArrayConstraint
    private let weightConstraint: MLMultiArrayConstraint

    init(models: [String: MLModel]) throws {
        guard let fbank = models["FBank"], let embedding = models["Embedding"],
            let audio = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
            let weights = embedding.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint,
            audio.shape.map(\.intValue) == [1, 1, 160_000], audio.dataType == .float32,
            weights.shape.map(\.intValue) == [1, 589], weights.dataType == .float32,
            let features = embedding.modelDescription.inputDescriptionsByName["fbank_features"]?.multiArrayConstraint,
            features.shape.map(\.intValue) == [1, 1, 80, 998], features.dataType == .float32,
            fbank.modelDescription.outputDescriptionsByName["fbank_features"] != nil,
            embedding.modelDescription.outputDescriptionsByName["embedding"] != nil
        else { throw ServiceError("The voice model has an unsupported input format.") }
        self.fbank = fbank
        self.embedding = embedding
        audioConstraint = audio
        weightConstraint = weights
    }

    /// 16 kHz mono speech. The caller excludes overlap and retains provenance.
    /// Returns a raw vector; callers normalize and attach its explicit model type.
    func extract(samples: [Float]) throws -> [Double] {
        try Task.checkCancellation()
        let audioCount = audioConstraint.shape.reduce(1) { $0 * $1.intValue }
        guard samples.count >= 32_000, samples.count <= audioCount, samples.allSatisfy(\.isFinite) else {
            throw ServiceError("Voice recognition needs between two and ten seconds of clear speech.")
        }
        let audio = try MLMultiArray(shape: audioConstraint.shape, dataType: audioConstraint.dataType)
        for index in 0..<audio.count {
            audio[index] = NSNumber(value: index < samples.count ? samples[index] : 0)
        }
        let features = try fbank.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
        try Task.checkCancellation()
        guard let fbankValues = features.featureValue(for: "fbank_features")?.multiArrayValue,
            fbankValues.shape.map(\.intValue) == [1, 1, 80, 998], fbankValues.dataType == .float32
        else {
            throw ServiceError("The voice model returned no speech features.")
        }
        // FBANK centers over all ten seconds, including zero-padded audio. Remove
        // that offset using only real STFT frames before the convolutional encoder.
        let centered = try SpeechSpanFeaturePolicy.centered(
            (0..<fbankValues.count).map { fbankValues[$0].doubleValue }, sampleCount: samples.count)
        let correctedFeatures = try MLMultiArray(shape: fbankValues.shape, dataType: fbankValues.dataType)
        for index in centered.indices { correctedFeatures[index] = NSNumber(value: centered[index]) }
        let weights = try MLMultiArray(shape: weightConstraint.shape, dataType: weightConstraint.dataType)
        let active = max(
            1, min(weights.count, Int((Double(samples.count) / Double(audioCount) * Double(weights.count)).rounded())))
        for index in 0..<weights.count { weights[index] = NSNumber(value: index < active ? 1 : 0) }
        let output = try embedding.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "fbank_features": MLFeatureValue(multiArray: correctedFeatures),
                "weights": MLFeatureValue(multiArray: weights),
            ]))
        try Task.checkCancellation()
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue,
            vector.shape.map(\.intValue) == [1, 256]
        else {
            throw ServiceError("The voice model returned an invalid embedding.")
        }
        let values = (0..<vector.count).map { vector[$0].doubleValue }
        guard values.allSatisfy(\.isFinite), values.contains(where: { $0 != 0 }) else {
            throw ServiceError("The selected speech did not produce a usable voice embedding.")
        }
        return values
    }

}

/// Geometry is fixed by the pinned FBANK graph: 400-sample frames, 160-sample
/// hop, no edge padding, 80 mel bins. The 589-frame mask is resampled by the
/// embedding graph; keep its existing duration mapping independently of centering.
enum SpeechSpanFeaturePolicy {
    static func activeFrameCount(sampleCount: Int) throws -> Int {
        guard (32_000...160_000).contains(sampleCount) else {
            throw ServiceError("Voice recognition needs between two and ten seconds of clear speech.")
        }
        return (sampleCount - 400) / 160 + 1
    }

    static func centered(_ features: [Double], sampleCount: Int) throws -> [Double] {
        let active = try activeFrameCount(sampleCount: sampleCount)
        let frames = 998
        guard features.count == 80 * frames, features.allSatisfy(\.isFinite) else {
            throw ServiceError("The voice model returned invalid speech features.")
        }
        var result = [Double](repeating: 0, count: features.count)
        for bin in 0..<80 {
            let start = bin * frames
            let mean = features[start..<(start + active)].reduce(0, +) / Double(active)
            for frame in 0..<active { result[start + frame] = features[start + frame] - mean }
        }
        guard result.allSatisfy(\.isFinite) else {
            throw ServiceError("The voice model returned invalid speech features.")
        }
        return result
    }
}
