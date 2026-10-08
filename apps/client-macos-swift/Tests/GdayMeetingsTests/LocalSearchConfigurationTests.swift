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
        var provider = ServiceProvider(kind: .localSearch)
        provider.localSearch = .init(
            semanticModel: .granite311M, speakerMatchBoost: 0.15)
        var settings = legacy
        settings.serviceProviders = [provider]
        settings.selectProvider(provider.id, for: .search)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.serviceProviders.first == provider)
        #expect(restored.selectedProvider(for: .search) == provider.id)
        #expect(restored.selectedSearchProvider == provider)
        #expect(!provider.kind.isLocalSpeaker)
        #expect(provider.kind.isLocal)
        #expect(provider.kind.capabilities == [.search])
    }

    @Test func localSearchDefaultsMigrateOnceWithoutRestoringRemovedProviders() throws {
        let fresh = AppSettings()
        #expect(fresh.serviceProviders.first?.kind == .localSearch)
        #expect(fresh.searchProviderID == fresh.serviceProviders.first?.id)
        var migrated = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"defaultSearchMode":"text"}"#.utf8))
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated))
        #expect(restored.selectedSearchProvider?.kind == .localSearch)
        #expect(restored.serviceProviders.count == 2)
        #expect(Set(restored.serviceProviders.map(\.kind)) == [.localSearch, .speakerLabeling])
        #expect(restored.serviceProviders.first { $0.id == restored.diarizationProviderID }?.kind == .speakerLabeling)
        migrated.serviceProviders = []
        let removed = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated))
        #expect(removed.serviceProviders.isEmpty)
    }

    @Test(arguments: ["text", "fusion", "semantic"])
    func obsoleteModeCannotOverrideGeneralProviderSelection(_ mode: String) throws {
        let first = ServiceProvider(kind: .localSearch)
        let selected = ServiceProvider(kind: .localSearch)
        var settings = AppSettings()
        settings.serviceProviders = [first, selected]
        settings.selectProvider(selected.id, for: .search)
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        saved["defaultSearchMode"] = mode

        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: saved))

        #expect(restored.selectedSearchProvider == selected)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(encoded["defaultSearchMode"] == nil)
    }

    @Test func unavailableSelectedProviderDoesNotFallBackToAnotherProvider() {
        let first = ServiceProvider(kind: .localSearch)
        var selected = ServiceProvider(kind: .localSearch)
        selected.isEnabled = false
        var settings = AppSettings()
        settings.serviceProviders = [first, selected]
        settings.selectProvider(selected.id, for: .search)
        #expect(settings.selectedSearchProvider == nil)
        settings.selectProvider(nil, for: .search)
        #expect(settings.selectedSearchProvider == nil)
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
