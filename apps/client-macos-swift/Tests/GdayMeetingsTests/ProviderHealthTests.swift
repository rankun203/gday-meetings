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

    @Test func liveLabelingNeedsBothModelsAndRecordedLabelingOnlyNeedsCommunity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("test".utf8)
        let manager = LocalModelManager(
            root: root,
            descriptor: { id in
                .init(
                    id: id, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
                    assets: [
                        .init(
                            path: "data", remotePath: "data", bytes: 4,
                            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                    ], modelNames: [])
            })
        let provider = ServiceProvider(kind: .speakerLabeling)
        let community = manager.modelDirectory(for: .community1)
        try FileManager.default.createDirectory(at: community, withIntermediateDirectories: true)
        try data.write(to: community.appendingPathComponent("data"))
        #expect(await provider.health(for: .diarization, settings: .init(), models: manager) == .ready)
        #expect(!(await provider.health(for: .liveDiarization, settings: .init(), models: manager)).isReady)
        let nemotron = manager.modelDirectory(for: .nemotronLow)
        try FileManager.default.createDirectory(at: nemotron, withIntermediateDirectories: true)
        try data.write(to: nemotron.appendingPathComponent("data"))
        #expect(await provider.health(for: .liveDiarization, settings: .init(), models: manager) == .ready)
        try await manager.remove(.community1)
        #expect(!(await provider.health(for: .liveDiarization, settings: .init(), models: manager)).isReady)
        #expect(!(await provider.health(for: .diarization, settings: .init(), models: manager)).isReady)
    }

    @Test func localHealthInspectsFilesWithoutPreparingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = LocalModelDescriptor(
            id: .community1, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
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
        #expect(!(await manager.health(for: .community1)).isReady)
        let directory = manager.modelDirectory(for: .community1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(await manager.health(for: .community1) == .ready)
        try Data("pinned".utf8).write(to: directory.appendingPathComponent(".gday-prepared"))
        #expect(await manager.health(for: .community1) == .ready)
        #expect(manager.state(for: .community1).phase == .missing)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(!(await manager.health(for: .community1)).isReady)
    }
}
