import Foundation

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
}

struct SpeakerEvidenceActivity: Codable, Equatable, Sendable {
    var source: String
    var localSpeakerID: String
    var start: Double
    var end: Double
}

struct SpeakerEvidenceWindow: Codable, Equatable, Sendable {
    static let protectedPolicy = "nemotron-capacity-rollover-v1"
    var generation: String
    var source: String
    var localSpeakerIDs: [String]
    var publicationStart: Double
    var observedEnd: Double
    var capacityReachedAt: Double?
    var policyRevision: String

    var isValid: Bool {
        !generation.isEmpty && !source.isEmpty && !policyRevision.isEmpty && !localSpeakerIDs.isEmpty
            && localSpeakerIDs.allSatisfy { !$0.isEmpty }
            && Set(localSpeakerIDs).count == localSpeakerIDs.count
            && publicationStart.isFinite && observedEnd.isFinite && publicationStart >= 0
            && observedEnd >= publicationStart
            && (capacityReachedAt.map { $0.isFinite && $0 >= 0 && $0 <= observedEnd } ?? true)
    }

    /// Saturated bootstrap can reach capacity before publication starts. It provides
    /// context but establishes no trusted continuation after the handoff.
    var trustedEnd: Double? {
        guard isValid, policyRevision == Self.protectedPolicy else { return nil }
        return max(publicationStart, min(observedEnd, capacityReachedAt ?? observedEnd))
    }
}

struct SpeakerEvidenceOmission: Codable, Equatable, Sendable {
    var source: String
    var localSpeakerID: String
    var start: Double
    var end: Double
    var reason: String

    var isValid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
            && !source.isEmpty && !localSpeakerID.isEmpty && !reason.isEmpty
    }
}

struct SpeakerEvidenceDocument: Codable, Equatable, Sendable {
    var samples: [SpeakerEvidenceSample] = []
    var activity: [SpeakerEvidenceActivity] = []
    /// Missing metadata is unknown provenance, never implicit continuity permission.
    var windows: [SpeakerEvidenceWindow]?
    /// Selected speech excerpts omitted by extraction backpressure; audio is retained.
    var extractionOmissions: [SpeakerEvidenceOmission]?

    mutating func recordWindow(_ window: SpeakerEvidenceWindow) throws {
        guard window.isValid else { throw CocoaError(.fileReadCorruptFile) }
        var values = windows ?? []
        if let index = values.firstIndex(where: { $0.source == window.source && $0.generation == window.generation }) {
            let previous = values[index]
            guard previous.publicationStart == window.publicationStart,
                Set(previous.localSpeakerIDs) == Set(window.localSpeakerIDs),
                previous.policyRevision == window.policyRevision,
                window.observedEnd >= previous.observedEnd,
                previous.capacityReachedAt == nil || previous.capacityReachedAt == window.capacityReachedAt,
                previous.capacityReachedAt != nil || previous.observedEnd == previous.publicationStart
                    || (window.capacityReachedAt.map { $0 >= previous.observedEnd } ?? true)
            else { throw CocoaError(.fileReadCorruptFile) }
            values[index] = window
        }
        else {
            guard
                !values.contains(where: {
                    $0.source == window.source
                        && (!Set($0.localSpeakerIDs).isDisjoint(with: window.localSpeakerIDs)
                            || ($0.publicationStart < window.observedEnd && window.publicationStart < $0.observedEnd))
                })
            else { throw CocoaError(.fileReadCorruptFile) }
            values.append(window)
        }
        windows = values.sorted {
            if $0.publicationStart != $1.publicationStart { return $0.publicationStart < $1.publicationStart }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.generation < $1.generation
        }
    }
}

struct SpeakerConsolidationResult: Codable, Equatable, Sendable {
    struct Cluster: Codable, Equatable, Sendable {
        var id: String
        var model: EmbeddingType
        var sampleIDs: [String]
        var representativeSampleIDs: [String]
    }
    struct Interval: Codable, Equatable, Sendable {
        var source: String
        var localSpeakerID: String
        var start: Double
        var end: Double
        var clusterID: String?
        var unresolvedReason: String?
    }
    var clusters: [Cluster]
    var intervals: [Interval]
    var rejectedSampleIDs: [String]
}
