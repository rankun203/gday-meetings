import CoreML
import Foundation

/// Extracts one voice vector from a caller-selected, non-overlapping speech span.
/// This uses the same pinned FBANK/WeSpeaker assets as Community-1, but does not
/// run segmentation or clustering. Keep its model lease alive while using it.
actor CommunityVoiceEmbeddingExtractor {
    private let fbank: MLModel
    private let embedding: MLModel
    private let audioConstraint: MLMultiArrayConstraint
    private let weightConstraint: MLMultiArrayConstraint

    init(models: [String: MLModel]) throws {
        guard let fbank = models["FBank"], let embedding = models["Embedding"],
            let audio = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
            let weights = embedding.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint,
            Self.validShape(audio.shape, maximum: 160_000),
            Self.validShape(weights.shape, maximum: 10_000),
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
        guard let fbankValues = features.featureValue(for: "fbank_features")?.multiArrayValue else {
            throw ServiceError("The voice model returned no speech features.")
        }
        let weights = try MLMultiArray(shape: weightConstraint.shape, dataType: weightConstraint.dataType)
        let active = max(
            1, min(weights.count, Int((Double(samples.count) / Double(audioCount) * Double(weights.count)).rounded())))
        for index in 0..<weights.count { weights[index] = NSNumber(value: index < active ? 1 : 0) }
        let output = try embedding.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "fbank_features": MLFeatureValue(multiArray: fbankValues),
                "weights": MLFeatureValue(multiArray: weights),
            ]))
        try Task.checkCancellation()
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue, vector.count == 256 else {
            throw ServiceError("The voice model returned an invalid embedding.")
        }
        let values = (0..<vector.count).map { vector[$0].doubleValue }
        guard values.allSatisfy(\.isFinite), values.contains(where: { $0 != 0 }) else {
            throw ServiceError("The selected speech did not produce a usable voice embedding.")
        }
        return values
    }

    private static func validShape(_ shape: [NSNumber], maximum: Int) -> Bool {
        var count = 1
        for value in shape {
            let dimension = value.intValue
            guard dimension > 0, dimension <= maximum / count else { return false }
            count *= dimension
        }
        return !shape.isEmpty && count <= maximum
    }
}
