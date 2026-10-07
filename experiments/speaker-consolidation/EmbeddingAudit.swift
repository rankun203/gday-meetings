// Diagnostic only: changing feature centering changes embedding compatibility.
import AVFoundation
import CoreML
import Foundation

struct ServiceError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}
@main struct Audit {
  static func main() async throws {
    guard CommandLine.arguments.count == 6 else {
      throw ServiceError(
        "Expected experiment directory, sample ID, evidence JSON, model directory, and output JSON")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let sampleID = CommandLine.arguments[2]
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let spec = (manifest["samples"] as! [[String: Any]]).first { $0["id"] as? String == sampleID }!
    let document = try JSONDecoder().decode(
      SpeakerEvidenceDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    guard document.samples.count >= 4 else { throw ServiceError("Expected at least four samples") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[4])
    var models: [String: MLModel] = [:]
    for name in ["FBank", "Embedding"] {
      let config = MLModelConfiguration()
      config.computeUnits = name == "FBank" ? .cpuOnly : .all
      models[name] = try MLModel(
        contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
    }
    let extractor = try CommunityVoiceEmbeddingExtractor(models: models)
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: spec["audioPath"] as! String))
    var outputs: [[String: Any]] = []
    var originalVectors: [[Double]] = []
    var correctedVectors: [[Double]] = []
    for index in [
      0, document.samples.count / 3, document.samples.count * 2 / 3, document.samples.count - 1,
    ] {
      let sample = document.samples[index]
      let count = Int(((sample.end - sample.start) * 16000).rounded())
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
      file.framePosition = AVAudioFramePosition((sample.start * 16000).rounded())
      try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
      let pcm = Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      let raw = try await extractor.extract(samples: pcm)
      let production = TypedVoiceEmbedding.normalizing(
        type: CommunityVoiceEmbeddingExtractor.embeddingType, values: raw)!
      let fbank = models["FBank"]!
      let constraint = fbank.modelDescription.inputDescriptionsByName["audio"]!
        .multiArrayConstraint!
      let input = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
      for i in 0..<input.count { input[i] = NSNumber(value: i < pcm.count ? pcm[i] : 0) }
      let output = try await fbank.prediction(
        from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)]))
      let features = output.featureValue(for: "fbank_features")!.multiArrayValue!
      let frames = features.shape.last!.intValue
      let active = min(frames, (count - 400) / 160 + 1)
      var activeMeanSquare = 0.0
      var fullMeanSquare = 0.0
      for bin in 0..<80 {
        let mean =
          (0..<active).reduce(0.0) { $0 + features[bin * frames + $1].doubleValue } / Double(active)
        let full =
          (0..<frames).reduce(0.0) { $0 + features[bin * frames + $1].doubleValue } / Double(frames)
        activeMeanSquare += mean * mean
        fullMeanSquare += full * full
      }
      let correctedFeatures = try MLMultiArray(shape: features.shape, dataType: features.dataType)
      for bin in 0..<80 {
        let mean =
          (0..<active).reduce(0.0) { $0 + features[bin * frames + $1].doubleValue } / Double(active)
        for frame in 0..<frames {
          correctedFeatures[bin * frames + frame] = NSNumber(
            value: frame < active ? features[bin * frames + frame].doubleValue - mean : 0)
        }
      }
      let embeddingModel = models["Embedding"]!
      let wc = embeddingModel.modelDescription.inputDescriptionsByName["weights"]!
        .multiArrayConstraint!
      let weights = try MLMultiArray(shape: wc.shape, dataType: wc.dataType)
      let activeWeights = Int((Double(count) / 160000 * Double(weights.count)).rounded())
      for i in 0..<weights.count { weights[i] = NSNumber(value: i < activeWeights ? 1 : 0) }
      let originalOutput = try await embeddingModel.prediction(
        from: MLDictionaryFeatureProvider(dictionary: [
          "fbank_features": MLFeatureValue(multiArray: features),
          "weights": MLFeatureValue(multiArray: weights),
        ]))
      let ov = originalOutput.featureValue(for: "embedding")!.multiArrayValue!
      let embedded = TypedVoiceEmbedding.normalizing(
        type: .community1, values: (0..<ov.count).map { ov[$0].doubleValue })!
      let cosine = zip(embedded.values, sample.vector).reduce(0) { $0 + $1.0 * $1.1 }
      let correctedOutput = try await embeddingModel.prediction(
        from: MLDictionaryFeatureProvider(dictionary: [
          "fbank_features": MLFeatureValue(multiArray: correctedFeatures),
          "weights": MLFeatureValue(multiArray: weights),
        ]))
      let cv = correctedOutput.featureValue(for: "embedding")!.multiArrayValue!
      let corrected = TypedVoiceEmbedding.normalizing(
        type: CommunityVoiceEmbeddingExtractor.embeddingType,
        values: (0..<cv.count).map { cv[$0].doubleValue })!
      let delta = zip(corrected.values, embedded.values).reduce(0) { $0 + $1.0 * $1.1 }
      originalVectors.append(embedded.values)
      correctedVectors.append(corrected.values)
      outputs.append([
        "productionCorrectedCosine": zip(production.values, corrected.values).reduce(0) {
          $0 + $1.0 * $1.1
        },
        "originalCorrectedCosine": delta, "sampleIndex": index,
        "durationSeconds": sample.end - sample.start, "cosineToRetained": cosine,
        "activeFbankMeanRMS": sqrt(activeMeanSquare / 80),
        "fullFbankMeanRMS": sqrt(fullMeanSquare / 80),
      ])
    }
    let pairs = (0..<4).flatMap { i in
      ((i + 1)..<4).map { j in
        [
          "leftIndex": i, "rightIndex": j,
          "originalCosine": zip(originalVectors[i], originalVectors[j]).reduce(0) {
            $0 + $1.0 * $1.1
          },
          "correctedCosine": zip(correctedVectors[i], correctedVectors[j]).reduce(0) {
            $0 + $1.0 * $1.1
          },
        ] as [String: Any]
      }
    }
    let data = try JSONSerialization.data(
      withJSONObject: ["samples": outputs, "pairs": pairs], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[5]), options: .withoutOverwriting)
    print(String(data: data, encoding: .utf8)!)
  }
}
