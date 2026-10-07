import AVFoundation
import CoreML
import Foundation

struct ServiceError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

/// Re-extracts existing timed spans with the current production preprocessing.
@main struct Reextract {
  static func main() async throws {
    guard CommandLine.arguments.count == 5 else {
      throw ServiceError("Expected audio WAV, evidence JSON, model directory, and output JSON")
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
      throw ServiceError("Expected 16 kHz mono audio")
    }
    var evidence = try JSONDecoder().decode(
      SpeakerEvidenceDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let directory = URL(fileURLWithPath: CommandLine.arguments[3])
    var models: [String: MLModel] = [:]
    for name in ["FBank", "Embedding"] {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = name == "FBank" ? .cpuOnly : .all
      models[name] = try MLModel(
        contentsOf: directory.appendingPathComponent(name + ".mlmodelc"),
        configuration: configuration)
    }
    let extractor = try CommunityVoiceEmbeddingExtractor(models: models)
    let start = Date()
    for index in evidence.samples.indices {
      let sample = evidence.samples[index]
      let count = Int(((sample.end - sample.start) * 16_000).rounded())
      guard count > 0,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
      else { throw ServiceError("Invalid retained span") }
      file.framePosition = AVAudioFramePosition((sample.start * 16_000).rounded())
      try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
      guard Int(buffer.frameLength) == count, let values = buffer.floatChannelData?[0] else {
        throw ServiceError("Retained span exceeds audio")
      }
      let vector = try await extractor.extract(
        samples: Array(UnsafeBufferPointer(start: values, count: count)))
      guard
        let typed = TypedVoiceEmbedding.normalizing(
          type: CommunityVoiceEmbeddingExtractor.embeddingType, values: vector)
      else {
        throw ServiceError("Invalid replacement embedding")
      }
      evidence.samples[index].embedding = typed
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(evidence).write(
      to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .withoutOverwriting)
    print(
      "{\"sampleCount\":\(evidence.samples.count),\"reextractionSeconds\":\(Date().timeIntervalSince(start))}"
    )
  }
}
