import CryptoKit
import Foundation

/// Evaluate the exact production candidate; the earlier receipt-only experiment stays separate.
@main struct TrustedChannelConsolidate {
  struct Run: Decodable {
    var rollover: String
    var returncode: Int
    var artifacts: [String: String]
  }
  struct Replay: Decodable {
    var complete: Bool
    var gapCount: Int
    var failureCount: Int
    var extractionFailures: Int
  }
  struct Audit: Codable {
    var method = SpeakerConsolidation.revision
    var evidenceSHA256: String
    var originalEvidenceSHA256: String
    var originalRunReceiptSHA256: String
    var threshold: Double
    var clusteringSeconds: Double
    var analysis: SpeakerConsolidation.Audit
  }
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func main() throws {
    guard CommandLine.arguments.count == 7, let threshold = Double(CommandLine.arguments[6]) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let paths = CommandLine.arguments.dropFirst().prefix(5).map { URL(fileURLWithPath: $0) }
    let data = try paths.prefix(3).map { try Data(contentsOf: $0) }
    let decoder = JSONDecoder()
    let evidence = try decoder.decode(SpeakerEvidenceDocument.self, from: data[0])
    let original = try decoder.decode(SpeakerEvidenceDocument.self, from: data[1])
    let run = try decoder.decode(Run.self, from: data[2])
    let replayData = try Data(
      contentsOf: paths[1].deletingLastPathComponent().appendingPathComponent("receipt.json"))
    let replay = try decoder.decode(Replay.self, from: replayData)
    guard run.rollover == "on", run.returncode == 0,
      run.artifacts["evidence.json"] == hash(data[1]),
      run.artifacts["receipt.json"] == hash(replayData), replay.complete, replay.gapCount == 0,
      replay.failureCount == 0, replay.extractionFailures == 0, evidence.windows != nil,
      evidence.windows == original.windows, evidence.activity == original.activity,
      evidence.samples.count == original.samples.count
    else { throw CocoaError(.fileReadCorruptFile) }
    for (sample, old) in zip(evidence.samples, original.samples) {
      guard sample.id == old.id, sample.source == old.source,
        sample.localSpeakerID == old.localSpeakerID,
        sample.start == old.start, sample.end == old.end, sample.model == .community1SpeechSpan
      else { throw CocoaError(.fileReadCorruptFile) }
    }
    let started = Date()
    let analysis = try SpeakerConsolidation.run(
      evidence, configuration: .init(minimumSimilarity: threshold))
    let audit = Audit(
      evidenceSHA256: hash(data[0]), originalEvidenceSHA256: hash(data[1]),
      originalRunReceiptSHA256: hash(data[2]), threshold: threshold,
      clusteringSeconds: Date().timeIntervalSince(started), analysis: analysis.audit)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(analysis.result).write(to: paths[3], options: .withoutOverwriting)
    try encoder.encode(audit).write(to: paths[4], options: .withoutOverwriting)
    print(
      "units=\(analysis.audit.units.count) clusters=\(analysis.result.clusters.count) clusteringSeconds=\(audit.clusteringSeconds)"
    )
  }
}
