import Combine
import CryptoKit
import Foundation

/// Dismissing the notice never changes voice evidence or review decisions.
@MainActor final class VoiceReviewNotice: ObservableObject {
    @Published private(set) var dismissedExampleIDs: Set<UUID>
    private let defaults: UserDefaults
    private let key: String

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let identity = directory.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        key = "dismissedVoiceReviewExamples.\(digest)"
        dismissedExampleIDs = Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func isVisible(for examples: [VoiceExample]) -> Bool {
        examples.contains { $0.needsReview && !dismissedExampleIDs.contains($0.id) }
    }

    func dismiss(examples: [VoiceExample]) {
        dismissedExampleIDs = Set(examples.filter(\.needsReview).map(\.id))
        defaults.set(dismissedExampleIDs.map(\.uuidString).sorted(), forKey: key)
    }

    static func voiceCount(in examples: [VoiceExample]) -> Int {
        Set(examples.filter(\.needsReview).map(\.groupID)).count
    }
}
