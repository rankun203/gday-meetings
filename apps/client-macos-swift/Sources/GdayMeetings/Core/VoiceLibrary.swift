import CryptoKit
import Foundation

enum VoiceReviewState: String, Codable, Sendable {
    case unassigned, suggested, confirmed, rejected
}

enum VoiceExampleOrigin: String, Codable, Sendable {
    case legacyProfile, savedSpeaker, liveSpeech, discovery
}

/// Optional playback location for a voice sample. Identity decisions and model
/// representations remain usable when the source recording is unavailable.
struct VoiceSampleRange: Codable, Equatable, Sendable {
    var audioFile: String
    var source: String
    var start: Double
    var end: Double
    var spans: [SpeakerEvidenceSpan]? = nil

    private enum CodingKeys: String, CodingKey { case audioFile, source, start, end, spans }
    init(audioFile: String, source: String, start: Double, end: Double, spans: [SpeakerEvidenceSpan]? = nil) {
        self.audioFile = audioFile
        self.source = source
        self.start = start
        self.end = end
        self.spans = spans
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioFile = try values.decode(String.self, forKey: .audioFile)
        source = try values.decode(String.self, forKey: .source)
        let legacyStart = try values.decode(Double.self, forKey: .start)
        let legacyEnd = try values.decode(Double.self, forKey: .end)
        spans = try values.decodeIfPresent([SpeakerEvidenceSpan].self, forKey: .spans)
        start = spans?.first?.start ?? legacyStart
        end = spans?.last?.end ?? legacyEnd
        if spans != nil {
            guard isValid, (legacyStart == 0 && legacyEnd == 0) || (legacyStart == start && legacyEnd == end) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .spans, in: values,
                    debugDescription: "Invalid fragmented voice sample range")
            }
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(audioFile, forKey: .audioFile)
        try values.encode(source, forKey: .source)
        // Older apps ignore spans. An invalid legacy range prevents them from
        // playing other speakers in the gaps or inventing a transcript fallback.
        try values.encode(spans == nil ? start : 0, forKey: .start)
        try values.encode(spans == nil ? end : 0, forKey: .end)
        try values.encodeIfPresent(spans, forKey: .spans)
    }

    var supportSpans: [SpeakerEvidenceSpan] { spans ?? [.init(start: start, end: end)] }
    var speechDuration: Double { supportSpans.reduce(0) { $0 + $1.end - $1.start } }
    func contains(start: Double, end: Double) -> Bool {
        isValid && supportSpans.contains { start >= $0.start && end <= $0.end }
    }
    func overlaps(_ other: VoiceSampleRange) -> Bool {
        isValid && other.isValid && audioFile == other.audioFile
            && supportSpans.contains { span in other.supportSpans.contains { span.overlaps($0) } }
    }
    private var validSupport: Bool {
        let values = supportSpans
        return !values.isEmpty && values.allSatisfy(\.isValid)
            && values.first?.start == start && values.last?.end == end
            && zip(values, values.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    var isValid: Bool {
        !audioFile.isEmpty && !audioFile.hasPrefix("/") && !audioFile.split(separator: "/").contains("..")
            && start.isFinite && end.isFinite && start >= 0 && end > start && validSupport
    }
}

struct VoiceExample: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var meetingID: UUID
    var speakerID: UUID
    var source: String
    var audioFile: String?
    var audioRevision: String?
    var start: Double?
    var end: Double?
    var personID: UUID?
    var suggestedPersonID: UUID?
    var review: VoiceReviewState = .unassigned
    var rejectedPersonIDs: [UUID] = []
    var excluded = false
    var manuallyCleared = false
    var embeddings: [TypedVoiceEmbedding] = []
    var groupID = UUID()
    var manuallyGrouped = false
    var createdAt = Date()
    var origin: VoiceExampleOrigin?
    /// Stable evidence identity for automatically selected live representatives.
    var observationID: String?
    var firstPassage: VoiceSampleRange?
    var sourceResolutionIssue: String?
    var spans: [SpeakerEvidenceSpan]? = nil

    var voiceEmbeddings: [TypedVoiceEmbedding] { embeddings }

    var range: VoiceSampleRange? {
        guard let audioFile, let start, let end else { return nil }
        let value = VoiceSampleRange(audioFile: audioFile, source: source, start: start, end: end, spans: spans)
        return value.isValid ? value : nil
    }
    var isPlayable: Bool { range != nil }
    var needsReview: Bool {
        personID == nil && !excluded && !manuallyCleared && (review == .unassigned || review == .suggested)
    }
    var isReviewed: Bool { review == .confirmed || review == .rejected || excluded || manuallyCleared }
}

/// A durable nil decision is distinct from a speaker which has never been reviewed.
struct VoiceSpeakerDecision: Codable, Hashable, Sendable {
    var meetingID: UUID
    var speakerID: UUID
    var personID: UUID?
}

struct VoiceProjectionOrigin: Codable, Equatable, Sendable {
    var speakerID: UUID
    var personID: UUID?
    var manuallyAssigned: Bool?
    var confidence: Double?
    var manualReviewThrough: [String: Double]?

    static func identity(exampleID: UUID, segmentID: UUID) -> UUID {
        let hash = Array(SHA256.hash(data: Data((exampleID.uuidString + segmentID.uuidString).utf8)))
        return UUID(
            uuid: (
                hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
            ))
    }
}

struct VoiceExampleReviewSnapshot: Codable, Equatable {
    var id: UUID
    var personID: UUID?
    var suggestedPersonID: UUID?
    var review: VoiceReviewState
    var rejectedPersonIDs: [UUID]
    var excluded: Bool
    var manuallyCleared: Bool
    var groupID: UUID
    var manuallyGrouped: Bool

    init(_ example: VoiceExample) {
        id = example.id
        personID = example.personID
        suggestedPersonID = example.suggestedPersonID
        review = example.review
        rejectedPersonIDs = example.rejectedPersonIDs
        excluded = example.excluded
        manuallyCleared = example.manuallyCleared
        groupID = example.groupID
        manuallyGrouped = example.manuallyGrouped
    }

    func restore(_ example: inout VoiceExample) {
        example.personID = personID
        example.suggestedPersonID = suggestedPersonID
        example.review = review
        example.rejectedPersonIDs = rejectedPersonIDs
        example.excluded = excluded
        example.manuallyCleared = manuallyCleared
        example.groupID = groupID
        example.manuallyGrouped = manuallyGrouped
    }
}

struct VoiceLibraryUndo: Codable, Equatable {
    var examples: [VoiceExampleReviewSnapshot]
    var decisions: [VoiceSpeakerDecision]
}

struct VoiceLibraryDocument: Codable, Equatable {
    var version = 1
    var examples: [VoiceExample] = []
    var decisions: [VoiceSpeakerDecision] = []
    var undo: [VoiceLibraryUndo] = []
    var jobs: [VoicePreparationJob] = []
    var deletedPersonIDs: [UUID] = []
}
