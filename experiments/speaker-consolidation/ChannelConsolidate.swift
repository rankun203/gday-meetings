import CryptoKit
import Foundation

/// Experimental assumption: rollover-protected local channels represent one voice.
/// This executable never changes the production consolidation implementation.
@main
struct ChannelConsolidate {
  struct Audit: Codable {
    struct Unit: Codable {
      var localSpeakerID: String
      var source: String
      var sampleCount: Int
      var activitySeconds: Double
      var minimumSampleToMeanCosine: Double
      var meanSampleToMeanCosine: Double
    }
    var method = "normalized-channel-mean-complete-link-v1"
    var continuityAssumption =
      "Rollover-on local identities are trusted within each window; this does not prove unsampled voice stability."
    var evidenceSHA256: String
    var originalEvidenceSHA256: String
    var originalRunReceiptSHA256: String
    var threshold: Double
    var cannotLinkUnitPairs: Int
    var units: [Unit]
    var channelInferredSpeakerSeconds: Double
    var unresolvedSpeakerSeconds: Double
    var clusteringSeconds: Double
  }
  struct Unit {
    var key: String
    var sampleIndices: [Int]
    var vector: [Double]
    var model: EmbeddingType
    var activity: [SpeakerEvidenceActivity]
  }
  struct InputRun: Decodable {
    var rollover: String
    var returncode: Int
    var artifacts: [String: String]
  }
  struct ReplayReceipt: Decodable {
    var complete: Bool
    var gapCount: Int
    var failureCount: Int
    var extractionFailures: Int
  }
  static func fail(_ message: String) -> NSError {
    NSError(domain: "ChannelConsolidate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func key(source: String, local: String) -> String {
    "\(source.utf8.count):\(source)\(local)"
  }
  static func normalized(_ values: [Double]) throws -> [Double] {
    let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { throw fail("The mean voice embedding is invalid.") }
    return values.map { $0 / norm }
  }
  static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
    zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
  }
  static func overlap(_ lhs: [SpeakerEvidenceActivity], _ rhs: [SpeakerEvidenceActivity]) -> Bool {
    var i = 0
    var j = 0
    while i < lhs.count && j < rhs.count {
      if lhs[i].start < rhs[j].end && rhs[j].start < lhs[i].end { return true }
      if lhs[i].end <= rhs[j].end { i += 1 } else { j += 1 }
    }
    return false
  }
  static func seconds(_ intervals: [SpeakerEvidenceActivity]) -> Double {
    var total = 0.0
    var previousEnd = -Double.infinity
    for interval in intervals.sorted(by: { $0.start < $1.start }) {
      total += max(0, interval.end - max(interval.start, previousEnd))
      previousEnd = max(previousEnd, interval.end)
    }
    return total
  }
  static func main() throws {
    guard CommandLine.arguments.count == 7 else {
      throw fail(
        "Use: ChannelConsolidate EVIDENCE ORIGINAL_EVIDENCE RUN_RECEIPT RESULT AUDIT THRESHOLD")
    }
    let paths = CommandLine.arguments.dropFirst().prefix(5).map { URL(fileURLWithPath: $0) }
    guard let threshold = Double(CommandLine.arguments[6]), threshold.isFinite,
      (-1...1).contains(threshold)
    else {
      throw fail("Use a cosine threshold between -1 and 1.")
    }
    let bytes = try paths.prefix(3).map { try Data(contentsOf: $0) }
    let decoder = JSONDecoder()
    let evidence = try decoder.decode(SpeakerEvidenceDocument.self, from: bytes[0])
    let original = try decoder.decode(SpeakerEvidenceDocument.self, from: bytes[1])
    let run = try decoder.decode(InputRun.self, from: bytes[2])
    let replayBytes = try Data(
      contentsOf: paths[1].deletingLastPathComponent().appendingPathComponent("receipt.json"))
    let replay = try decoder.decode(ReplayReceipt.self, from: replayBytes)
    guard run.artifacts["receipt.json"] == digest(replayBytes), replay.complete,
      replay.gapCount == 0, replay.failureCount == 0, replay.extractionFailures == 0
    else { throw fail("The original replay must finish without gaps or extraction failures.") }
    guard run.rollover == "on", run.returncode == 0,
      run.artifacts["evidence.json"] == digest(bytes[1]),
      evidence.activity == original.activity, evidence.samples.count == original.samples.count
    else {
      throw fail(
        "This method requires unchanged activity from a successful, hash-verified rollover-on replay."
      )
    }
    for (sample, prior) in zip(evidence.samples, original.samples) {
      guard sample.id == prior.id, sample.source == prior.source,
        sample.localSpeakerID == prior.localSpeakerID,
        sample.start == prior.start, sample.end == prior.end, sample.embedding.isValid,
        sample.embedding.type == .community1SpeechSpan
      else {
        throw fail(
          "Corrected samples must preserve their source spans and use the corrected speech-span model type."
        )
      }
    }
    guard Set(evidence.samples.map(\.id)).count == evidence.samples.count,
      evidence.activity.allSatisfy({
        $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
      })
    else { throw fail("The evidence contains duplicate sample identities or invalid activity.") }
    let started = Date()
    let activity = Dictionary(grouping: evidence.activity) {
      key(source: $0.source, local: $0.localSpeakerID)
    }
    let sampleGroups = Dictionary(grouping: evidence.samples.indices) {
      key(source: evidence.samples[$0].source, local: evidence.samples[$0].localSpeakerID)
    }
    var unitAudit: [Audit.Unit] = []
    let units = try sampleGroups.keys.sorted().map { key -> Unit in
      let members = sampleGroups[key]!
      let first = evidence.samples[members[0]]
      var mean = [Double](repeating: 0, count: first.vector.count)
      for member in members {
        for index in mean.indices {
          mean[index] += evidence.samples[member].vector[index] / Double(members.count)
        }
      }
      mean = try normalized(mean)
      let spans = (activity[key] ?? []).sorted { $0.start < $1.start }
      let similarities = members.map { dot(mean, evidence.samples[$0].vector) }
      unitAudit.append(
        .init(
          localSpeakerID: first.localSpeakerID, source: first.source, sampleCount: members.count,
          activitySeconds: seconds(spans), minimumSampleToMeanCosine: similarities.min()!,
          meanSampleToMeanCosine: similarities.reduce(0, +) / Double(similarities.count)))
      return Unit(
        key: key, sampleIndices: members, vector: mean, model: first.model, activity: spans)
    }
    var similarities = Array(
      repeating: Array(repeating: -Double.infinity, count: units.count), count: units.count)
    var cannotLink = 0
    for i in units.indices {
      for j in units.indices where j > i {
        let sameSource = unitAudit[i].source == unitAudit[j].source
        if sameSource && overlap(units[i].activity, units[j].activity) {
          cannotLink += 1
          continue
        }
        similarities[i][j] = dot(units[i].vector, units[j].vector)
        similarities[j][i] = similarities[i][j]
      }
    }
    // Exact agglomerative complete-link across unit descriptors. A cannot-link
    // between any constituent units blocks a merge at every later step.
    var groups = units.indices.map { [$0] }
    while groups.count > 1 {
      var best: (Int, Int)?
      var bestSimilarity = -Double.infinity
      for i in groups.indices {
        for j in groups.indices where j > i {
          let similarity = groups[i].flatMap { a in groups[j].map { similarities[a][$0] } }.min()!
          if similarity >= threshold && similarity > bestSimilarity {
            best = (i, j)
            bestSimilarity = similarity
          }
        }
      }
      guard let (left, right) = best else { break }
      groups[left] = (groups[left] + groups[right]).sorted()
      groups.remove(at: right)
    }
    var assignment: [String: String] = [:]
    let clusters = groups.map { group -> SpeakerConsolidationResult.Cluster in
      let samples = group.flatMap { units[$0].sampleIndices }.map { evidence.samples[$0] }
      let memberIDs = samples.map(\.id).sorted()
      let identity =
        (["channel-mean-v1", EmbeddingType.community1SpeechSpan.compatibilityVersion] + memberIDs)
        .map { "\($0.utf8.count):\($0)" }.joined()
      let id = "voice-" + digest(Data(identity.utf8))
      for unit in group { assignment[units[unit].key] = id }
      return .init(
        id: id, model: samples[0].model, sampleIDs: memberIDs,
        representativeSampleIDs: VoiceProfileSelection.select(samples, limit: 3).map(\.id))
    }
    let intervals = evidence.activity.map { interval -> SpeakerConsolidationResult.Interval in
      let id = assignment[key(source: interval.source, local: interval.localSpeakerID)]
      return .init(
        source: interval.source, localSpeakerID: interval.localSpeakerID,
        start: interval.start, end: interval.end, clusterID: id,
        unresolvedReason: id == nil ? "No voice sample for this local channel" : nil)
    }
    let result = SpeakerConsolidationResult(
      clusters: clusters, intervals: intervals, rejectedSampleIDs: [])
    let inferred = activity.filter { assignment[$0.key] != nil }.values.reduce(0) {
      $0 + seconds($1)
    }
    let unresolved = activity.filter { assignment[$0.key] == nil }.values.reduce(0) {
      $0 + seconds($1)
    }
    let audit = Audit(
      evidenceSHA256: digest(bytes[0]), originalEvidenceSHA256: digest(bytes[1]),
      originalRunReceiptSHA256: digest(bytes[2]), threshold: threshold,
      cannotLinkUnitPairs: cannotLink,
      units: unitAudit, channelInferredSpeakerSeconds: inferred,
      unresolvedSpeakerSeconds: unresolved,
      clusteringSeconds: Date().timeIntervalSince(started))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(result).write(to: paths[3], options: .withoutOverwriting)
    try encoder.encode(audit).write(to: paths[4], options: .withoutOverwriting)
    print(
      "units=\(units.count) clusters=\(clusters.count) clusteringSeconds=\(audit.clusteringSeconds)"
    )
  }
}
