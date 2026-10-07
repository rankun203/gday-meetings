import Foundation

enum VoiceEmbeddingMath {
    static func normalized(_ vector: [Double]) -> [Double]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return vector.map { Double($0) / magnitude }
    }

    static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
