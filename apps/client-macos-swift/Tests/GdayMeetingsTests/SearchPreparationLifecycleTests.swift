import Foundation
import Testing

@testable import GdayMeetings

private actor LifecycleEmbedding: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID = .granite97M
    let waitForCancellation: Bool
    let onUnload: (@Sendable () async -> Void)?
    init(waitForCancellation: Bool = false, onUnload: (@Sendable () async -> Void)? = nil) {
        self.waitForCancellation = waitForCancellation
        self.onUnload = onUnload
    }
    private(set) var preparations = 0
    private(set) var releases = 0
    func prepare() async throws {
        preparations += 1
        try await Task.sleep(for: waitForCancellation ? .seconds(60) : .milliseconds(30))
    }
    func embed(_ text: String, isQuery: Bool) async throws -> [Double] { [1] }
    func passageParts(_ text: String) async throws -> [String] { [text] }
    func unload() async {
        releases += 1
        await onUnload?()
    }
}

private actor SearchRetirementGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct SearchPreparationLifecycleTests {
    @Test func typingAndSubmissionSharePreparationAndIndexingOwnsSeparateResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = LifecycleEmbedding()
        let passage = LifecycleEmbedding()
        var queryCreations = 0
        var passageCreations = 0
        let controller = LocalSearchController(
            directory: directory, indexDirectory: directory.appendingPathComponent("indexes"),
            makeEncoder: { _, usage in
                if usage == .query {
                    queryCreations += 1
                    return query
                }
                passageCreations += 1
                return passage
            })
        let provider = ServiceProvider(kind: .localSearch)
        #expect(queryCreations == 0)
        controller.configurationChanged(provider)
        #expect(queryCreations == 0)
        controller.typingBegan(provider)
        controller.typingBegan(provider)
        _ = try await controller.prepare(provider)
        #expect(queryCreations == 1)
        #expect(await query.preparations == 1)
        #expect(passageCreations == 0)
        let indexing = try await controller.indexingProvider(provider)
        try await indexing.prepare()
        #expect(passageCreations == 1)
        #expect(await passage.preparations == 1)
        #expect(await query.releases == 0)
        await controller.shutdown()
        #expect(await query.releases == 1)
        #expect(await passage.releases == 1)
        #expect(!controller.isReady)
    }

    @Test func shutdownDuringPreparationAllowsTheSameProviderToPrepareAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelled = LifecycleEmbedding(waitForCancellation: true)
        let replacement = LifecycleEmbedding()
        var creations = 0
        let controller = LocalSearchController(
            directory: directory, indexDirectory: directory.appendingPathComponent("indexes"),
            makeEncoder: { _, _ in
                creations += 1
                return creations == 1 ? cancelled : replacement
            })
        let provider = ServiceProvider(kind: .localSearch)
        let request = Task { try await controller.prepare(provider) }
        while await cancelled.preparations == 0 { await Task.yield() }
        await controller.shutdown()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        _ = try await controller.prepare(provider)
        #expect(creations == 2)
        #expect(controller.isReady)
        #expect(await cancelled.releases == 1)
        #expect(await replacement.preparations == 1)
        await controller.shutdown()
        #expect(await replacement.releases == 1)
    }

    @Test func shutdownRetiresOnlyItsCapturedQueryAndIndexGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SearchRetirementGate()
        let oldQuery = LifecycleEmbedding(onUnload: { await gate.wait() })
        let newQuery = LifecycleEmbedding()
        let newIndex = LifecycleEmbedding()
        var queryCreations = 0
        let controller = LocalSearchController(
            directory: directory, indexDirectory: directory.appendingPathComponent("indexes"),
            makeEncoder: { _, usage in
                if usage == .indexing { return newIndex }
                queryCreations += 1
                return queryCreations == 1 ? oldQuery : newQuery
            })
        let provider = ServiceProvider(kind: .localSearch)
        _ = try await controller.prepare(provider)
        let retirement = Task { await controller.shutdown() }
        while await oldQuery.releases == 0 { await Task.yield() }
        _ = try await controller.prepare(provider)
        let index = try await controller.indexingProvider(provider)
        try await index.prepare()
        await gate.open()
        await retirement.value
        #expect(controller.isReady)
        #expect(await newQuery.releases == 0)
        #expect(await newIndex.releases == 0)
        await controller.shutdown()
        #expect(await newQuery.releases == 1)
        #expect(await newIndex.releases == 1)
    }

    @Test func configurationChangeRetiresAnInflightQueryPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = LifecycleEmbedding(waitForCancellation: true)
        let controller = LocalSearchController(
            directory: directory, indexDirectory: directory.appendingPathComponent("indexes"),
            makeEncoder: { _, _ in query })
        let provider = ServiceProvider(kind: .localSearch)
        let request = Task { try await controller.prepare(provider) }
        while await query.preparations == 0 { await Task.yield() }
        controller.configurationChanged(nil)
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        await controller.shutdown()
        #expect(!controller.isReady)
        #expect(await query.releases == 1)
    }
}
