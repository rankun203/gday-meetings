import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ProviderHealthTests {
    @Test func disabledCapabilityDoesNotContactProvider() async {
        var provider = ServiceProvider(kind: .runpod)
        provider.enabledCapabilities = []
        #expect(
            await provider.health(for: .transcription, settings: AppSettings())
                == .notReady("Capability is turned off."))
    }

    @Test func configurationChangeDiscardsLateHealth() async {
        var continuation: CheckedContinuation<ProviderHealth, Never>?
        let health = ProviderHealthStore { _, _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        var settings = AppSettings()
        let provider = ServiceProvider(kind: .openAICompatible)
        settings.serviceProviders = [provider]
        let original = settings
        let task = Task { await health.check(providerID: provider.id, capability: .summarization, settings: original) }
        while continuation == nil { await Task.yield() }
        settings.serviceProviders[0].endpoint = "https://example.invalid/v1"
        health.invalidateChangedConfiguration(settings: settings)
        continuation?.resume(returning: .ready)
        _ = await task.value
        #expect(health.state(providerID: provider.id, capability: .summarization) == .checking)
    }

    @Test func staleDependencyCheckCannotRestoreOldConfiguration() async {
        var contacted: [UUID] = []
        let health = ProviderHealthStore { id, _, _ in
            contacted.append(id)
            return .ready
        }
        let provider = ServiceProvider(kind: .openAICompatible)
        let upload = ServiceProvider(kind: .filedrop)
        var current = AppSettings()
        current.serviceProviders = [provider, upload]
        let old = current
        current.serviceProviders[0].endpoint = "https://example.invalid/new"
        _ = await health.check(providerID: provider.id, capability: .summarization, settings: current)
        let dependency = await health.checkDependency(providerID: upload.id, capability: .fileTransfer, settings: old)
        #expect(!dependency.isReady)
        #expect(contacted == [provider.id])
        #expect(health.state(providerID: provider.id, capability: .summarization) == .ready)
        #expect(health.state(providerID: upload.id, capability: .fileTransfer) == .checking)
    }

    @Test func providerCapabilitySequenceCannotRestoreOldConfiguration() async {
        var pending: CheckedContinuation<ProviderHealth, Never>?
        var contacted: [UUID] = []
        let provider = ServiceProvider(kind: .runpod)
        let other = ServiceProvider(kind: .openAICompatible)
        let health = ProviderHealthStore { id, _, _ in
            contacted.append(id)
            if id == provider.id && pending == nil {
                return await withCheckedContinuation { pending = $0 }
            }
            return .ready
        }
        var settings = AppSettings()
        settings.serviceProviders = [provider, other]
        let old = settings
        let task = Task { await health.checkProvider(providerID: provider.id, settings: old) }
        while pending == nil { await Task.yield() }
        settings.serviceProviders[0].endpoint = "https://example.invalid/updated"
        _ = await health.check(providerID: other.id, capability: .summarization, settings: settings)
        pending?.resume(returning: .ready)
        _ = await task.value
        #expect(contacted.filter { $0 == provider.id }.count == 1)
        #expect(health.state(providerID: other.id, capability: .summarization) == .ready)
        for capability in provider.kind.capabilities {
            #expect(health.state(providerID: provider.id, capability: capability) == .checking)
        }
    }

    @Test func dropdownPublishesEachResultBeforeOthersFinish() async {
        var slow: CheckedContinuation<ProviderHealth, Never>?
        let first = ServiceProvider(kind: .openAICompatible)
        let second = ServiceProvider(kind: .openAICompatible)
        let health = ProviderHealthStore { id, _, _ in
            if id == second.id { return await withCheckedContinuation { slow = $0 } }
            return .ready
        }
        var settings = AppSettings()
        settings.serviceProviders = [first, second]
        let snapshot = settings
        let task = Task { await health.checkEligible(capability: .summarization, settings: snapshot) }
        while slow == nil || health.state(providerID: first.id, capability: .summarization) != .ready {
            await Task.yield()
        }
        #expect(health.state(providerID: second.id, capability: .summarization) == .checking)
        slow?.resume(returning: .notReady("Provider is unavailable."))
        await task.value
        #expect(health.state(providerID: first.id, capability: .summarization) == .ready)
        #expect(!health.state(providerID: second.id, capability: .summarization).isReady)
    }

    @Test func selectedChecksDoNotContactOtherProviders() async {
        var contacted: Set<UUID> = []
        let health = ProviderHealthStore { id, _, _ in
            contacted.insert(id)
            return .ready
        }
        let selected = ServiceProvider(kind: .openAICompatible)
        let unused = ServiceProvider(kind: .openAICompatible)
        var settings = AppSettings()
        settings.liveTranscriptionProviderID = nil
        settings.serviceProviders = [selected, unused]
        settings.summaryProviderID = selected.id
        await health.checkSelected(settings: settings)
        #expect(contacted == [selected.id])
    }

    @Test func overlappingChecksShareOneRequest() async {
        var calls = 0
        var pending: CheckedContinuation<ProviderHealth, Never>?
        let health = ProviderHealthStore { _, _, _ in
            calls += 1
            return await withCheckedContinuation { pending = $0 }
        }
        let provider = ServiceProvider(kind: .openAICompatible)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        let snapshot = settings
        let first = Task { await health.check(providerID: provider.id, capability: .summarization, settings: snapshot) }
        while pending == nil { await Task.yield() }
        let second = Task {
            await health.check(providerID: provider.id, capability: .summarization, settings: snapshot)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(calls == 1)
        pending?.resume(returning: .ready)
        #expect(await first.value == .ready)
        #expect(await second.value == .ready)
    }

    @Test func localModelCompletionAssignsUnconfiguredAssociationWithoutCheckingRemoteProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let local = ServiceProvider(kind: .nemotron)
        let remote = ServiceProvider(kind: .openAICompatible)
        store.settings.serviceProviders = [local, remote]
        store.settings.selectProvider(local.id, for: .liveDiarization)
        store.settings.recordExplicitFeatureChoice(\.recognizeSpeakers, enabled: false)
        var embeddingReady = false
        var checked: [UUID] = []
        let health = ProviderHealthStore { id, capability, _ in
            checked.append(id)
            return capability == .speakerRecognition && !embeddingReady ? .notReady("Model is preparing.") : .ready
        }
        await store.refreshLocalProviderHealth(health: health)
        #expect(store.settings.speakerRecognitionProviderID == nil)
        embeddingReady = true
        await store.refreshLocalProviderHealth(health: health)
        #expect(store.settings.speakerRecognitionProviderID == local.id)
        #expect(store.settings.recognizeLiveSpeakers)
        #expect(!store.settings.recognizeSpeakers)
        #expect(!checked.contains(remote.id))
        #expect(health.state(providerID: local.id, capability: .speakerRecognition) == .ready)
    }

    @Test func localModelCompletionPreservesExplicitNoneAndDisabledFeatures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let provider = ServiceProvider(kind: .nemotron)
        store.settings.serviceProviders = [provider]
        store.settings.selectProvider(nil, for: .speakerRecognition)
        var checked: Set<ProviderCapability> = []
        let health = ProviderHealthStore { _, capability, _ in
            checked.insert(capability)
            return .ready
        }
        await store.refreshLocalProviderHealth(health: health)
        #expect(store.settings.speakerRecognitionProviderID == nil)
        #expect(!checked.contains(.speakerRecognition))
        #expect(store.settings.liveDiarizationProviderID == provider.id)
    }

    @Test func nemotronAssociationUsesEmbeddingHealthIndependentlyOfLabelingPreset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("test".utf8)
        let descriptor = LocalModelDescriptor(
            id: .voiceEmbedding, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
            assets: [
                .init(
                    path: "data", remotePath: "data", bytes: 4,
                    digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            ],
            modelNames: ["Model"])
        let manager = LocalModelManager(
            root: root, descriptor: { _ in descriptor },
            preparer: { _, _ in
                Issue.record("Health must not load a model")
                return [:]
            })
        let directory = manager.modelDirectory(for: .voiceEmbedding)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("data"))
        let provider = ServiceProvider(kind: .nemotron)
        #expect(provider.supports(.speakerRecognition))
        #expect(await provider.health(for: .speakerRecognition, settings: AppSettings(), models: manager) == .ready)
        #expect(!(await provider.health(for: .liveDiarization, settings: AppSettings(), models: manager)).isReady)
        try Data("oops".utf8).write(to: directory.appendingPathComponent("data"))
        // Availability checks file identity and size; acquisition performs content validation.
        #expect(await provider.health(for: .speakerRecognition, settings: AppSettings(), models: manager) == .ready)
        await #expect(throws: LocalModelError.self) { _ = try await manager.acquire(.voiceEmbedding) }
    }

    @Test func existingNemotronProvidersGainAssociationButExplicitDisableSurvivesReload() throws {
        let provider = ServiceProvider(kind: .nemotron)
        let data = try JSONEncoder().encode(provider)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "capabilityVersion")
        old["enabledCapabilities"] = [ProviderCapability.liveDiarization.rawValue]
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.supports(.speakerRecognition))
        var disabled = restored
        disabled.enabledCapabilities.remove(.speakerRecognition)
        let reloaded = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(disabled))
        #expect(!reloaded.supports(.speakerRecognition))
        #expect(reloaded.supports(.liveDiarization))
    }

    @Test func localHealthInspectsFilesWithoutPreparingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = LocalModelDescriptor(
            id: .voiceEmbedding, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
            assets: [
                .init(
                    path: "data", remotePath: "data", bytes: 4,
                    digest: SHA256.hash(data: Data("test".utf8)).map { String(format: "%02x", $0) }.joined())
            ], modelNames: ["Model"])
        let manager = LocalModelManager(
            root: root, descriptor: { _ in descriptor },
            preparer: { _, _ in
                Issue.record("Readiness must not prepare a model")
                return [:]
            })
        #expect(!(await manager.health(for: .voiceEmbedding)).isReady)
        let directory = manager.modelDirectory(for: .voiceEmbedding)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(await manager.health(for: .voiceEmbedding) == .ready)
        try Data("pinned".utf8).write(to: directory.appendingPathComponent(".gday-prepared"))
        #expect(await manager.health(for: .voiceEmbedding) == .ready)
        #expect(manager.state(for: .voiceEmbedding).phase == .missing)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(!(await manager.health(for: .voiceEmbedding)).isReady)
    }
}
