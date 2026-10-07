import Foundation

@main struct Bench {
    static let vector = TypedVoiceEmbedding(type: .community1SpeechSpan, values: [1] + Array(repeating: 0, count: 255))
    static func sample(_ i: Int, label: String, start: Double) -> SpeakerEvidenceSample {
        .init(
            id: "sample-\(i)", source: "microphone", localSpeakerID: label, start: start, end: start + 3,
            embedding: vector)
    }
    static func run(_ count: Int, units: Bool) throws {
        let samples = (0..<count).map { sample($0, label: units ? "local-\($0)" : "local", start: Double($0 * 5)) }
        let activity = samples.map {
            SpeakerEvidenceActivity(source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
        }
        let windows: [SpeakerEvidenceWindow] =
            units
            ? samples.enumerated().map { index, sample in
                .init(
                    generation: "generation-\(index)", source: "microphone", localSpeakerIDs: [sample.localSpeakerID],
                    publicationStart: sample.start, observedEnd: sample.end,
                    policyRevision: SpeakerEvidenceWindow.protectedPolicy)
            }
            : [
                .init(
                    generation: "generation", source: "microphone", localSpeakerIDs: ["local"], publicationStart: 0,
                    observedEnd: Double(count * 5), policyRevision: SpeakerEvidenceWindow.protectedPolicy)
            ]
        let doc = SpeakerEvidenceDocument(samples: samples, activity: activity, windows: windows)
        let start = Date()
        let result = try SpeakerConsolidation.run(doc)
        print(
            "\(units ? "units" : "samples") count=\(count) seconds=\(Date().timeIntervalSince(start)) clusters=\(result.result.clusters.count)"
        )
    }
    static func main() throws {
        for count in [720, 1440, 2880, 5760] { try run(count, units: false) }
        for count in [64, 128, 256, 512] { try run(count, units: true) }
    }
}
