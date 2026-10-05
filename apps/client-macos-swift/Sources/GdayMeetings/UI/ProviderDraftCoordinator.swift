import AppKit
import Combine
import Foundation

/// App-owned drafts survive Settings window closure without saving credentials.
@MainActor
final class ProviderDraftCoordinator: ObservableObject {
    enum Decision { case save, discard, cancel }
    @Published var selection: UUID?
    @Published private var drafts: [UUID: ServiceProvider] = [:]
    private var isConfirming = false

    func draft(for saved: ServiceProvider) -> ServiceProvider { drafts[saved.id] ?? saved }
    func update(_ provider: ServiceProvider) { drafts[provider.id] = provider }
    func clear(_ id: UUID) { drafts.removeValue(forKey: id) }
    func select(_ id: UUID, authorize: () -> Bool) {
        guard id != selection, authorize() else { return }
        selection = id
    }
    func hasChanges(in saved: [ServiceProvider]) -> Bool {
        saved.contains { provider in drafts[provider.id].map { $0 != provider } ?? false }
    }

    /// A failed write retains every draft and prevents the requested transition.
    func resolve(_ decision: Decision, saved: [ServiceProvider], persist: ([ServiceProvider]) -> Bool) -> Bool {
        switch decision {
        case .cancel: return false
        case .discard:
            drafts.removeAll()
            return true
        case .save:
            let providers = saved.map { provider in
                guard var value = drafts[provider.id] else { return provider }
                value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                value.endpoint = value.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                return value
            }
            guard providers.allSatisfy({ !$0.name.isEmpty }), persist(providers) else { return false }
            drafts.removeAll()
            return true
        }
    }

    func confirmLeaving(store: MeetingStore) -> Bool {
        guard hasChanges(in: store.settings.serviceProviders) else { return true }
        guard !isConfirming else { return false }
        isConfirming = true
        defer { isConfirming = false }
        let alert = NSAlert()
        alert.messageText = "Save changes to provider settings?"
        alert.informativeText = "Save your changes, discard them, or cancel to continue editing."
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        let decision: Decision =
            response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel
        var error: String?
        let accepted = resolve(decision, saved: store.settings.serviceProviders) { providers in
            let previous = store.settings
            store.settings.serviceProviders = providers
            guard store.saveSettings() else {
                store.settings = previous
                error = store.errorMessage ?? "Couldn’t save provider settings. Try again."
                return false
            }
            return true
        }
        if !accepted, decision == .save {
            let failure = NSAlert()
            failure.messageText = "Couldn’t Save Provider Settings"
            failure.informativeText = error ?? "Enter a name for each provider, then save again."
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
        return accepted
    }
}
