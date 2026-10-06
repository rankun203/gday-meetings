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
            executableURL: URL(fileURLWithPath: "/synthetic/worker"),
            modelCacheURL: URL(fileURLWithPath: "/synthetic/models"))
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
            modelNames: ["CLSPAudio", "CLSPText"])
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
        provider.localSearch = .init(
            executableURL: URL(fileURLWithPath: "/nonexistent/legacy-worker"),
            modelCacheURL: URL(fileURLWithPath: "/nonexistent/legacy-cache"))
        #expect(await provider.health(for: .search, settings: AppSettings(), models: manager) == .ready)
        try Data("changed".utf8).write(to: directory.appendingPathComponent("data"))
        #expect(!(await provider.health(for: .search, settings: AppSettings(), models: manager)).isReady)
    }

    @Test func readinessChecksMetadataWithoutStartingWorker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("model.fixture")
        try Data("fixture".utf8).write(to: file)
        let executable = root.appendingPathComponent("worker")
        // If validation ever launches this executable, it must fail rather than appear ready.
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let date = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        func manifest(path: String) throws {
            let value: [String: Any] = [
                "version": 1, "modelID": LocalSearchConfiguration.modelID,
                "modelRevision": LocalSearchConfiguration.modelRevision,
                "tokenizerRevision": LocalSearchConfiguration.tokenizerRevision,
                "files": [
                    [
                        "path": path, "size": 7, "modified": date.timeIntervalSince1970,
                        "sha256": String(repeating: "a", count: 64),
                    ]
                ],
            ]
            try JSONSerialization.data(withJSONObject: value).write(
                to: root.appendingPathComponent("gday-clsp-prepared.json"))
        }
        let config = LocalSearchConfiguration(executableURL: executable, modelCacheURL: root)
        try manifest(path: "model.fixture")
        try config.validatePreparedFiles()
        try manifest(path: "../outside.fixture")
        #expect(throws: (any Error).self) { try config.validatePreparedFiles() }
        try manifest(path: "model.fixture")
        try Data("changed fixture".utf8).write(to: file)
        #expect(throws: (any Error).self) { try config.validatePreparedFiles() }
        let directoryExecutable = LocalSearchConfiguration(executableURL: root, modelCacheURL: root)
        #expect(throws: (any Error).self) { try directoryExecutable.validatePreparedFiles() }
    }
}
