import CoreML
import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

private actor CancellationPreparation {
    var calls = 0
    func prepare() async throws -> [String: MLModel] {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .seconds(60)) }
        return [:]
    }
}

private actor RemovalBarrier {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct ModelCapabilityLifecycleTests {
    private let bytes = Data("synthetic model assets".utf8)
    private func fixture(
        removal: LocalModelFiles.Remover? = nil,
        preparation: @escaping @Sendable (LocalModelDescriptor, URL) async throws -> [String: MLModel] = { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return [:]
        }
    ) throws -> (URL, LocalModelManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = bytes
        let manager = LocalModelManager(
            root: root,
            descriptor: { id in
                .init(
                    id: id, title: "Synthetic Model", repository: "synthetic/model", revision: "pinned",
                    assets: [
                        .init(
                            path: "data", remotePath: "data", bytes: Int64(data.count),
                            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                    ],
                    modelNames: ["Synthetic"])
            },
            preparer: preparation, remover: removal)
        let directory = manager.modelDirectory(for: .granite97M)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("data"))
        return (root, manager)
    }

    @Test func removalReservesTheModelBeforeYielding() async throws {
        let barrier = RemovalBarrier()
        let (root, manager) = try fixture(removal: { _ in await barrier.wait() })
        defer { try? FileManager.default.removeItem(at: root) }
        let removal = Task { try await manager.remove(.granite97M) }
        while !(await barrier.entered) { await Task.yield() }
        let error = await #expect(throws: LocalModelError.self) { _ = try await manager.acquire(.granite97M) }
        if case .busy? = error {
        }
        else {
            Issue.record("Acquisition must reject an in-flight removal.")
        }
        #expect(manager.state(for: .granite97M).inUse == 0)
        await barrier.release()
        try await removal.value
        #expect(manager.state(for: .granite97M).inUse == 0)
        #expect(manager.state(for: .granite97M).phase == .missing)
    }

    @Test func suspendedMaintenancePreparationCanBeCancelledWithoutResumingCapture() async throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await ProcessingCoordinator.shared.setMaintenanceSuspended(true)
        let encoder = CoreMLSemanticEmbedding(modelID: .granite97M, manager: manager, usage: .indexing)
        let operation = Task { try await encoder.prepare() }
        while manager.state(for: .granite97M).inUse == 0 { await Task.yield() }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await encoder.unload()
        #expect(manager.state(for: .granite97M).inUse == 0)
        #expect(manager.state(for: .granite97M).phase == .cancelled)
        await ProcessingCoordinator.shared.setMaintenanceSuspended(false)
    }

    @Test func copiedCommunityAssetsAreUsedDirectlyWithoutAnotherInstallation() async throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = manager.modelDirectory(for: .community1)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bytes.write(to: source.appendingPathComponent("data"))
        #expect(await manager.health(for: .community1) == .ready)
        #expect(await manager.lifecycleMetrics().verificationPasses == 0)
        #expect(await manager.lifecycleMetrics().preparationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("voiceEmbedding").path))
        let lease = try await manager.acquire(.community1)
        #expect(await manager.lifecycleMetrics().preparationCount == 1)
        manager.release(lease)
        #expect(manager.state(for: .community1).inUse == 0)
    }

    @Test func availabilityDoesNotHashOrLoadAndAcquisitionLoadsOnce() async throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<20 { #expect(await manager.health(for: .granite97M) == .ready) }
        let before = await manager.lifecycleMetrics()
        #expect(before.verificationPasses == 0)
        #expect(before.preparationCount == 0)
        let first = try await manager.acquire(.granite97M)
        manager.release(first)
        let second = try await manager.acquire(.granite97M)
        manager.release(second)
        let after = await manager.lifecycleMetrics()
        #expect(after.verificationPasses == 1)
        #expect(after.hashedBytes == Int64(bytes.count))
        #expect(after.preparationCount == 2)
        #expect(after.preparationSeconds > 0)
        #expect(manager.state(for: .granite97M).inUse == 0)
    }

    @Test func strongChecksShareTemporaryPreparationAndChangedIdentityInvalidatesReceipt() async throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { await manager.validate(.granite97M) }
        let second = Task { await manager.validate(.granite97M) }
        #expect(await first.value == .ready)
        #expect(await second.value == .ready)
        #expect(await manager.validate(.granite97M) == .ready)
        #expect(await manager.lifecycleMetrics().preparationCount == 1)
        #expect(manager.state(for: .granite97M).inUse == 0)
        let file = manager.modelDirectory(for: .granite97M).appendingPathComponent("data")
        let modified = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data(repeating: 7, count: bytes.count).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        // Availability is an estimate; same-length replacement must fail actual verification.
        await #expect(throws: LocalModelError.self) { _ = try await manager.acquire(.granite97M) }
        #expect(await manager.lifecycleMetrics().preparationCount == 1)
        #expect(manager.state(for: .granite97M).inUse == 0)
    }

    @Test func cancelledAcquisitionReleasesItsReservation() async throws {
        let gate = CancellationPreparation()
        let (root, manager) = try fixture(preparation: { _, _ in try await gate.prepare() })
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await manager.acquire(.granite97M) }
        while await gate.calls == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(manager.state(for: .granite97M).inUse == 0)
        let retry = try await manager.acquire(.granite97M)
        manager.release(retry)
    }

    @Test func providerValidationDoesNotReplaceGeneralAvailabilityAndSharesInflightCheck() async {
        var continuation: CheckedContinuation<ProviderHealth, Never>?
        var calls = 0
        let health = ProviderHealthStore { _, _, _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let provider = ServiceProvider(kind: .localSearch)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        health.seed(providerID: provider.id, capability: .search, health: .ready)
        // A separate nonseeded provider exercises real validation publication.
        let other = ServiceProvider(kind: .localSearch)
        settings.serviceProviders.append(other)
        let snapshot = settings
        let first = Task { await health.checkProvider(providerID: other.id, settings: snapshot) }
        while continuation == nil { await Task.yield() }
        let second = Task { await health.checkProvider(providerID: other.id, settings: snapshot) }
        await Task.yield()
        #expect(health.state(providerID: provider.id, capability: .search) == .ready)
        #expect(health.validationState(providerID: other.id, capability: .search) == .checking)
        continuation?.resume(returning: .ready)
        #expect(await first.value[.search] == .ready)
        #expect(await second.value[.search] == .ready)
        #expect(calls == 1)
        #expect(health.validationState(providerID: other.id, capability: .search) == .ready)
    }

    @Test func semanticConfigurationSurvivesLeftoverRetiredWorkerFields() throws {
        var provider = ServiceProvider(kind: .localSearch)
        provider.localSearch = .init(semanticModel: .granite97M, speakerMatchBoost: 0.2)
        provider.model = "CLSP"
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
        var configuration = try #require(value["localSearch"] as? [String: Any])
        configuration["executableURL"] = "file:///synthetic/retired-worker"
        value["localSearch"] = configuration
        let decoded = try JSONDecoder().decode(
            ServiceProvider.self, from: JSONSerialization.data(withJSONObject: value))
        #expect(decoded.supports(.search))
        #expect(decoded.localSearch?.semanticModel == .granite97M)
        #expect(decoded.localSearch?.speakerMatchBoost == 0.2)
    }

    @Test func oldWorkerConfigurationCannotReactivateRetiredCapability() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","kind":"localSearch","name":"Local Voice Search","endpoint":"","model":"CLSP","isEnabled":true,"enabledCapabilities":["search"],"localSearch":{"executableURL":"file:///synthetic/worker","modelCacheURL":"file:///synthetic/cache"}}"#
                .utf8)
        let provider = try JSONDecoder().decode(ServiceProvider.self, from: data)
        #expect(!provider.supports(.search))
        #expect(provider.model.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(provider), as: UTF8.self)
        #expect(!encoded.contains("executableURL"))
        #expect(!encoded.contains("modelCacheURL"))
    }
}
