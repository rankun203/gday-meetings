import Foundation

/// Runtime activity belongs to an operation, independently of provider readiness.
/// Adapters supply descriptions so callers can present preparation without knowing the provider.
enum ProviderActivity: Equatable, Sendable {
    case idle
    case loading(String)
    case active
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .loading(let message), .failed(let message): message
        default: nil
        }
    }
}
