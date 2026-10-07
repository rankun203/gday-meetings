import Foundation

/// Semantic text search uses managed local assets. Retired subprocess fields are ignored on decode.
struct LocalSearchConfiguration: Codable, Equatable, Sendable {
    var semanticModel: SemanticModelID?
    var speakerMatchBoost: Double?
    var selectedModel: SemanticModelID { semanticModel ?? .granite97M }
    var boost: Double {
        let value = speakerMatchBoost ?? 0.1
        return value.isFinite ? min(0.2, max(0, value)) : 0.1
    }
}
