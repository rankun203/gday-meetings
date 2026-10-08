import Foundation

/// Analyze a derived, source-separated evidence document without changing a meeting.
/// The caller retains each replay receipt and the source-remapping receipt.
@main struct ProjectorConsolidate {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let evidence = try JSONDecoder().decode(SpeakerEvidenceDocument.self, from: Data(contentsOf: input))
        let analysis = try SpeakerConsolidation.run(evidence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(analysis).write(to: output, options: .withoutOverwriting)
        print("samples=\(evidence.samples.count) units=\(analysis.audit.units.count) clusters=\(analysis.result.clusters.count)")
    }
}
