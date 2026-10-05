import Foundation
import Testing

@testable import GdayMeetings

struct LocalSearchConfigurationTests {
    @Test func providerAndSearchDefaultsRoundTripWithoutAffectingLegacySettings() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(legacy.searchProviderID == nil)
        #expect(legacy.defaultSearchMode == .text)
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
        #expect(restored.defaultSearchMode == .fusion)
        #expect(!provider.kind.isLocalSpeaker)
        #expect(provider.kind.isLocal)
        #expect(provider.kind.capabilities == [.search])
    }

    @MainActor @Test func missingConfigurationNeverAdvertisesReady() async {
        let provider = ServiceProvider(kind: .localSearch)
        let result = await provider.health(for: .search, settings: AppSettings())
        #expect(!result.isReady)
        #expect(!ProviderConfigurationEligibility.canSelect(provider, for: .search, providers: [provider]))
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
