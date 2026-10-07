import Foundation

@main struct ConflictBench {
    static func original(_ examples: [VoiceExample]) -> Set<UUID> {
        Set(
            examples.compactMap { example in
                guard example.review == .confirmed, !example.excluded, let range = example.range else { return nil }
                return examples.contains { other in
                    guard other.id != example.id, other.meetingID == example.meetingID,
                        other.audioRevision == example.audioRevision, other.review == .confirmed,
                        other.personID != example.personID, !other.excluded, let otherRange = other.range
                    else { return false }
                    return otherRange.audioFile == range.audioFile && otherRange.start < range.end
                        && otherRange.end > range.start
                } ? example.id : nil
            })
    }

    static func main() throws {
        let meeting = UUID()
        let people: [UUID?] = [UUID(), UUID(), UUID(), nil]
        for count in [2000, 4000, 8000] {
            let examples = (0..<count).map { index in
                VoiceExample(
                    meetingID: meeting, speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
                    audioRevision: "synthetic", start: Double(index * 4), end: Double(index * 4 + 3),
                    personID: people[index % people.count], review: .confirmed)
            }
            let baselineStart = Date()
            let baseline = original(examples)
            let baselineSeconds = Date().timeIntervalSince(baselineStart)
            let optimizedStart = Date()
            let optimized = VoiceReviewConflicts.confirmedExampleIDs(in: examples)
            let optimizedSeconds = Date().timeIntervalSince(optimizedStart)
            guard baseline == optimized else { throw CocoaError(.coderInvalidValue) }
            print(
                "examples count=\(count) baselineSeconds=\(baselineSeconds) optimizedSeconds=\(optimizedSeconds) conflicts=\(optimized.count)"
            )
        }
    }
}
