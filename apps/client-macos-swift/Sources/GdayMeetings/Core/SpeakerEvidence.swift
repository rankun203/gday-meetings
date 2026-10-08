import Foundation

/// Physical support in the recorded source; gaps between spans are never audio evidence.
struct SpeakerEvidenceSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
    func overlaps(_ other: Self) -> Bool { start < other.end && other.start < end }
}

struct SpeakerEvidenceSample: Codable, Equatable, Sendable {
    var id: String
    var source: String
    var localSpeakerID: String
    var start: Double
    var end: Double
    var embedding: TypedVoiceEmbedding
    var model: EmbeddingType { embedding.type }
    var vector: [Double] { embedding.values }
    var quality: Double = 1
    /// Nil preserves legacy contiguous samples. start/end enclose, but do not fill, these spans.
    var spans: [SpeakerEvidenceSpan]? = nil
    var supportSpans: [SpeakerEvidenceSpan] { spans ?? [.init(start: start, end: end)] }
    var speechDuration: Double { supportSpans.reduce(0) { $0 + $1.end - $1.start } }
    var hasValidSupport: Bool {
        let support = supportSpans
        guard !support.isEmpty, support.allSatisfy(\.isValid),
            support.first!.start == start, support.last!.end == end
        else { return false }
        return zip(support, support.dropFirst()).allSatisfy { $0.end <= $1.start }
    }
    func covers(_ time: Double) -> Bool { supportSpans.contains { $0.start <= time && time < $0.end } }
    func overlapsSupport(of other: Self) -> Bool {
        supportSpans.contains { left in other.supportSpans.contains { left.overlaps($0) } }
    }
}
