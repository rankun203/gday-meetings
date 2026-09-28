import SwiftUI

/// An edit owns its commit callback until it finishes. Publishing draft changes
/// never calls persistence; focus changes and view removal can safely finish the
/// same session more than once.
@MainActor
final class TranscriptEditSession: ObservableObject {
    @Published var draft = ""
    @Published private(set) var isEditing = false
    private var original = ""
    private var save: ((String) -> Void)?

    func begin(text: String, save: @escaping (String) -> Void) {
        guard !isEditing else { return }
        original = String(text.drop(while: { $0.isWhitespace }))
        draft = original
        self.save = save
        isEditing = true
    }

    func finish(cancel: Bool = false) {
        guard isEditing else { return }
        let commit = save
        save = nil
        isEditing = false
        if !cancel && draft != original { commit?(draft) }
    }
}
