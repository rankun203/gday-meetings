import Foundation

@main struct ObservationIdentityEvaluation {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        let evidence = try decoder.decode(
            SpeakerEvidenceDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var configuration = SpeakerConsolidation.Configuration()
        #if !BASELINE
        configuration.observationPolicy = .init(minimumSimilarity: 0.72, minimumMargin: 0.08, prototypeLimit: 12)
        configuration.maximumContinuityGap = 15
        #endif
        let started = Date()
        let analysis = try SpeakerConsolidation.run(evidence, configuration: configuration)
        let clusteringSeconds = Date().timeIntervalSince(started)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis.result).write(
            to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
        struct Receipt: Encodable {
            let configuration: SpeakerConsolidation.Configuration
            let clusteringSeconds: Double
            let analysis: SpeakerConsolidation.Audit
        }
        try encoder.encode(Receipt(configuration: configuration, clusteringSeconds: clusteringSeconds, analysis: analysis.audit)).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .withoutOverwriting)
    }
}
