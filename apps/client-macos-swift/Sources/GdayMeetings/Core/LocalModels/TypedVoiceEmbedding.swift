import Foundation

/// Equality is a compatibility contract, not a similarity of names or dimensions.
struct EmbeddingType: Codable, Hashable, Sendable {
    var modelID: String
    var revision: String
    var compatibilityVersion: String
    var dimension: Int
    var normalization: String

    static let community1 = EmbeddingType(
        modelID: "FluidInference/community1-wespeaker-resnet34",
        revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        compatibilityVersion: "gday-span-mask-v1", dimension: 256, normalization: "unitL2")

    static func unknownLegacy(dimension: Int) -> EmbeddingType {
        .init(
            modelID: "unknown", revision: "unknown", compatibilityVersion: "unknown",
            dimension: dimension, normalization: "unknown")
    }

    var supportsMatching: Bool {
        modelID != "unknown" && !modelID.isEmpty && revision != "unknown" && !revision.isEmpty
            && compatibilityVersion != "unknown" && !compatibilityVersion.isEmpty
            && dimension > 0 && dimension <= 4096 && normalization == "unitL2"
    }
}

struct TypedVoiceEmbedding: Codable, Equatable, Sendable {
    var type: EmbeddingType
    var values: [Double]
    var provenance: String?

    init(type: EmbeddingType, values: [Double], provenance: String? = nil) {
        self.type = type
        self.values = values
        self.provenance = provenance
        // The repository's RunPod worker has always used Community-1. These
        // source labels identify that contract, not arbitrary 256-D vectors.
        if type.modelID == "unknown", let provenance,
            provenance == "legacy:rust:runpod" || provenance.hasPrefix("runpod:"),
            let normalized = Self.normalizing(type: .community1, values: values, provenance: provenance)
        {
            self = normalized
        }
    }

    private enum CodingKeys: String, CodingKey { case type, values, provenance }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try values.decode(EmbeddingType.self, forKey: .type),
            values: try values.decode([Double].self, forKey: .values),
            provenance: try values.decodeIfPresent(String.self, forKey: .provenance))
    }

    var isValid: Bool {
        type.supportsMatching && values.count == type.dimension && values.allSatisfy(\.isFinite)
            && abs(values.reduce(0) { $0 + $1 * $1 } - 1) < 0.001
    }

    static func normalizing(type: EmbeddingType, values: [Double], provenance: String? = nil) -> Self? {
        guard type.supportsMatching, values.count == type.dimension,
            values.allSatisfy(\.isFinite), let scale = values.map(abs).max(), scale > 0
        else { return nil }
        let scaled = values.map { $0 / scale }
        let norm = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
        let result = Self(type: type, values: scaled.map { $0 / norm }, provenance: provenance)
        return result.isValid ? result : nil
    }
}

struct VoiceMatch: Equatable, Sendable {
    let personID: UUID
    let score: Double
    let margin: Double
}
