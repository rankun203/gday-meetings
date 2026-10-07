import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

struct LocalSearchConfigurationTests {
    @Test func semanticInputShapesKeepDocumentsAndLongQueriesComplete() {
        for model in SemanticModelID.allCases {
            #expect(model.inputTokens(isQuery: true, tokenCount: 128) == 128)
            #expect(model.inputTokens(isQuery: true, tokenCount: 129) == 512)
            #expect(model.inputTokens(isQuery: true, tokenCount: 512) == 512)
            #expect(model.inputTokens(isQuery: false, tokenCount: 20) == 512)
            #expect(model.inputTokens(isQuery: false, tokenCount: 512) == 512)
        }
    }

    @Test func providerAndSearchDefaultsRoundTripWithoutAffectingLegacySettings() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(legacy.serviceProviders.first?.kind == .localSearch)
        #expect(legacy.searchProviderID == legacy.serviceProviders.first?.id)
        #expect(legacy.defaultSearchMode == .semantic)
        var provider = ServiceProvider(kind: .localSearch)
        provider.localSearch = .init(
            semanticModel: .granite311M, speakerMatchBoost: 0.15)
        var settings = legacy
        settings.serviceProviders = [provider]
        settings.selectProvider(provider.id, for: .search)
        settings.defaultSearchMode = .fusion
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.serviceProviders.first == provider)
        #expect(restored.selectedProvider(for: .search) == provider.id)
        #expect(restored.defaultSearchMode == .semantic)
        #expect(!provider.kind.isLocalSpeaker)
        #expect(provider.kind.isLocal)
        #expect(provider.kind.capabilities == [.search])
    }

    @Test func localSearchDefaultsMigrateOnceAndPreserveLaterTextChoice() throws {
        let fresh = AppSettings()
        #expect(fresh.serviceProviders.first?.kind == .localSearch)
        #expect(fresh.searchProviderID == fresh.serviceProviders.first?.id)
        var migrated = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"defaultSearchMode":"text"}"#.utf8))
        #expect(migrated.defaultSearchMode == .semantic)
        migrated.defaultSearchMode = .text
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated))
        #expect(restored.defaultSearchMode == .text)
        #expect(restored.serviceProviders.count == 1)
        migrated.serviceProviders = []
        let removed = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated))
        #expect(removed.serviceProviders.isEmpty)
    }

    @MainActor @Test func managedCoreMLFilesDetermineReadinessWithoutLegacyPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("synthetic model".utf8)
        let descriptor = LocalModelDescriptor(
            id: .granite97M, title: "Synthetic Embedding", repository: "synthetic/model", revision: "pinned",
            assets: [
                .init(
                    path: "data", remotePath: "data", bytes: Int64(bytes.count),
                    digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            ],
            modelNames: ["SemanticEncoder"])
        let manager = LocalModelManager(
            root: root, descriptor: { _ in descriptor },
            preparer: { _, _ in
                Issue.record("Readiness must not load the model")
                return [:]
            })
        var provider = ServiceProvider(kind: .localSearch)
        provider.localSearch = nil
        #expect(ProviderConfigurationEligibility.canSelect(provider, for: .search, providers: [provider]))
        #expect(!(await provider.health(for: .search, settings: AppSettings(), models: manager)).isReady)
        let directory = manager.modelDirectory(for: .granite97M)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("data"))
        #expect(await provider.health(for: .search, settings: AppSettings(), models: manager) == .ready)
        provider.localSearch = .init(semanticModel: .granite97M)
        #expect(await provider.health(for: .search, settings: AppSettings(), models: manager) == .ready)
        try Data("changed".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(!(await provider.health(for: .search, settings: AppSettings(), models: manager)).isReady)
    }

}
