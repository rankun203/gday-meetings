import Combine
import Foundation

/// Streamed text belongs to the Summary document, not the library's publisher.
@MainActor
final class SummaryDraftState: ObservableObject {
    @Published var values: [UUID: String] = [:]
}
