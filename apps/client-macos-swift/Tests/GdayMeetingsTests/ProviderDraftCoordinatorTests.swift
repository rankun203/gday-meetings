import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct ProviderDraftCoordinatorTests {
    @Test(arguments: [ServiceProviderKind.runpod, .openAICompatible, .nemotron, .community1])
    func cancelAndFailedSaveRetainDraft(kind: ServiceProviderKind) {
        let coordinator = ProviderDraftCoordinator()
        let saved = ServiceProvider(kind: kind)
        var edited = saved
        edited.name = "Synthetic edited provider"
        edited.apiKey = "synthetic-secret"
        coordinator.update(edited)
        #expect(coordinator.hasChanges(in: [saved]))
        var writes = 0
        #expect(
            !coordinator.resolve(.cancel, saved: [saved]) { _ in
                writes += 1
                return true
            })
        #expect(writes == 0)
        #expect(
            !coordinator.resolve(.save, saved: [saved]) { _ in
                writes += 1
                return false
            })
        #expect(writes == 1)
        #expect(coordinator.draft(for: saved) == edited)
        #expect(saved.apiKey.isEmpty)
        #expect(
            coordinator.resolve(.discard, saved: [saved]) { _ in
                writes += 1
                return true
            })
        #expect(writes == 1)
        #expect(coordinator.draft(for: saved) == saved)
    }

    @Test func saveCommitsNormalizedDraftAndPreservesOtherProviders() {
        let coordinator = ProviderDraftCoordinator()
        let first = ServiceProvider(kind: .filedrop)
        var second = ServiceProvider(kind: .openAICompatible)
        second.name = " Untouched provider "
        second.endpoint = " https://untouched.example.invalid "
        var edited = first
        edited.name = "  Synthetic upload  "
        edited.endpoint = " https://upload.example.invalid "
        coordinator.update(edited)
        var committed: [ServiceProvider] = []
        #expect(
            coordinator.resolve(.save, saved: [first, second]) {
                committed = $0
                return true
            })
        #expect(committed.first?.name == "Synthetic upload")
        #expect(committed.first?.endpoint == "https://upload.example.invalid")
        #expect(committed.last == second)
        #expect(!coordinator.hasChanges(in: committed))
    }

    @Test func invalidDraftBlocksTransitionWithoutWriting() {
        let coordinator = ProviderDraftCoordinator()
        let saved = ServiceProvider(kind: .runpod)
        var edited = saved
        edited.name = "   "
        coordinator.update(edited)
        var wrote = false
        #expect(
            !coordinator.resolve(.save, saved: [saved]) { _ in
                wrote = true
                return true
            })
        #expect(!wrote)
        #expect(coordinator.draft(for: saved).name == "   ")
    }

    @Test func repairRequestReplacesRetainedSelectionOnlyAfterAuthorization() {
        let coordinator = ProviderDraftCoordinator()
        let previous = ServiceProvider(kind: .runpod)
        let requested = ServiceProvider(kind: .filedrop)
        coordinator.selection = previous.id
        coordinator.update(previous)
        coordinator.select(requested.id) { false }
        #expect(coordinator.selection == previous.id)
        coordinator.select(requested.id) { true }
        #expect(coordinator.selection == requested.id)
        var askedAgain = false
        coordinator.select(requested.id) {
            askedAgain = true
            return false
        }
        #expect(!askedAgain)
        #expect(coordinator.selection == requested.id)
    }
}
