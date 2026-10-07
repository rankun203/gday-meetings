import Foundation

@main
struct Consolidate {
  static func main() throws {
    guard CommandLine.arguments.count == 4 else {
      throw NSError(
        domain: "Consolidate", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Use: Consolidate EVIDENCE OUTPUT THRESHOLD"])
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let threshold = Double(CommandLine.arguments[3]), threshold.isFinite,
      (-1...1).contains(threshold)
    else {
      throw NSError(domain: "Consolidate", code: 2)
    }
    let document = try JSONDecoder().decode(
      SpeakerEvidenceDocument.self, from: Data(contentsOf: input))
    let started = Date()
    let result = ExcerptSpeakerConsolidation.run(
      document, configuration: .init(minimumSimilarity: threshold))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(result).write(to: output, options: .withoutOverwriting)
    print("clusteringSeconds=\(Date().timeIntervalSince(started))")
  }
}
