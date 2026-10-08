import Foundation

@main struct CausalObservationReplay {
    struct Observation: Codable {
        var sample: SpeakerEvidenceSample
        var availableAt: Double
        var callbackOrdinal: Int
        var embeddingReadyAt: Double
    }
    struct Assignment: Codable, Equatable {
        var sampleID: String
        var availableAt: Double
        var callbackOrdinal: Int
        var embeddingReadyAt: Double
        var clusterID: String?
    }
    struct Result: Encodable {
        var configuration: SpeakerObservationClustering.Configuration
        var assignments: [Assignment]
        var clusterCount: Int
        var checkedPrefixLengths: [Int]
        var prefixInvariant: Bool
    }
    static func replay(_ observations: [Observation]) throws -> ([Assignment], Int) {
        var engine = SpeakerObservationClustering()
        var assignments: [Assignment] = []
        var previousClock = -Double.infinity
        var previousOrdinal = -1
        for observation in observations {
            guard observation.availableAt.isFinite, observation.embeddingReadyAt.isFinite,
                observation.availableAt >= previousClock, observation.callbackOrdinal >= previousOrdinal,
                observation.embeddingReadyAt >= observation.sample.end,
                observation.availableAt >= observation.embeddingReadyAt
            else { throw CocoaError(.fileReadCorruptFile) }
            let decision = try engine.ingest(observation.sample)
            let clusterID: String?
            switch decision {
            case .assigned(let id): clusterID = id
            case .ambiguous: clusterID = nil
            }
            assignments.append(.init(sampleID: observation.sample.id, availableAt: observation.availableAt,
                                     callbackOrdinal: observation.callbackOrdinal,
                                     embeddingReadyAt: observation.embeddingReadyAt, clusterID: clusterID))
            previousClock = observation.availableAt
            previousOrdinal = observation.callbackOrdinal
        }
        return (assignments, engine.clusters.count)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
        let observations = try JSONDecoder().decode([Observation].self, from: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1])))
        let (assignments, clusterCount) = try replay(observations)
        let lengths = Array(Set([0, min(1, observations.count), observations.count / 2, observations.count])).sorted()
        for length in lengths {
            guard try replay(Array(observations.prefix(length))).0 == Array(assignments.prefix(length))
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        let output = Result(configuration: .init(), assignments: assignments, clusterCount: clusterCount,
                            checkedPrefixLengths: lengths, prefixInvariant: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
    }
}
