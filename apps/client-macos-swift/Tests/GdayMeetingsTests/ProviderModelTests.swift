import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ProviderModelTests {
    private func llm(endpoint: String = "https://openrouter.ai/api/v1", key: String = "synthetic") -> ServiceProvider {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = endpoint
        provider.apiKey = key
        provider.enabledCapabilities = [.summarization]
        return provider
    }

    @Test func parsesIDsAndOptionalNamesAndSkipsMalformedEntries() throws {
        let response: [String: Any] = [
            "data": [
                ["id": "openai/gpt-4o", "name": "OpenAI: GPT-4o"],
                ["id": "anthropic/claude-sonnet"],
                ["id": "openai/gpt-4o", "name": "Duplicate"],
                ["id": ""], ["id": " padded "], ["name": "No ID"], ["id": "same", "name": "same"],
            ]
        ]
        let models = try ProviderModelList.parse(response)
        #expect(models.map(\.id) == ["anthropic/claude-sonnet", "openai/gpt-4o", "same"])
        #expect(models.first { $0.id == "openai/gpt-4o" }?.name == "OpenAI: GPT-4o")
        #expect(models.first { $0.id == "same" }?.name == nil)
        #expect(throws: (any Error).self) { try ProviderModelList.parse([:]) }
        #expect(throws: (any Error).self) { try ProviderModelList.parse(["data": [["id": ""]]]) }
    }

    @Test func requestSendsOnlyTheKeyToTheModelsPath() throws {
        let request = try ProviderModelList.request(llm())
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    }

    @Test func filterMatchesIDOrNameAndShowsAllForAnExactChoice() {
        let models = [
            ProviderModel(id: "openai/gpt-4o", name: "OpenAI: GPT-4o"),
            ProviderModel(id: "anthropic/claude-sonnet", name: "Anthropic: Claude Sonnet"),
        ]
        #expect(ProviderModelList.filter(models, query: "").count == 2)
        #expect(ProviderModelList.filter(models, query: "GPT").map(\.id) == ["openai/gpt-4o"])
        #expect(ProviderModelList.filter(models, query: "anthropic: claude").map(\.id) == ["anthropic/claude-sonnet"])
        #expect(ProviderModelList.filter(models, query: "openai/gpt-4o").count == 2)
        #expect(ProviderModelList.filter(models, query: "missing").isEmpty)
    }

    @Test func listingPolicyNeverContactsDisabledProvidersOnOpen() {
        let saved = llm()
        #expect(ProviderModelListPolicy.plan(draft: saved, saved: saved) == .immediate)
        var disabled = saved
        disabled.isEnabled = false
        #expect(ProviderModelListPolicy.plan(draft: disabled, saved: disabled) == .none)
        // Editing the endpoint or key of any provider lists models after typing pauses.
        var edited = disabled
        edited.apiKey = "typed"
        #expect(ProviderModelListPolicy.plan(draft: edited, saved: disabled) == .debounced)
        #expect(ProviderModelListPolicy.plan(draft: saved, saved: nil) == .debounced)
        // Incomplete or invalid fields, and other kinds, send nothing.
        #expect(ProviderModelListPolicy.plan(draft: llm(key: " "), saved: nil) == .none)
        #expect(ProviderModelListPolicy.plan(draft: llm(endpoint: "http://example.com/v1"), saved: nil) == .none)
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = "https://api.runpod.ai/v2/abc"
        runpod.apiKey = "synthetic"
        #expect(ProviderModelListPolicy.plan(draft: runpod, saved: runpod) == .none)
    }

    @Test func cachePersistsPerProviderAndEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = llm()
        let removed = llm()
        let models = [ProviderModel(id: "openai/gpt-4o", name: nil)]
        let cache = ProviderMetadataCache<[ProviderModel]>(directory: directory, fileName: "models.json")
        cache.store(
            .init(providerID: removed.id, fingerprint: "old", value: models, fetchedAt: Date()),
            keeping: [provider.id, removed.id])
        let fingerprint = ProviderModelList.fingerprint(provider)
        cache.store(
            .init(providerID: provider.id, fingerprint: fingerprint, value: models, fetchedAt: Date()),
            keeping: [provider.id])

        let reloaded = ProviderMetadataCache<[ProviderModel]>(directory: directory, fileName: "models.json")
        #expect(reloaded.entry(providerID: provider.id, fingerprint: fingerprint)?.value == models)
        #expect(reloaded.entry(providerID: removed.id, fingerprint: "old") == nil)
        var moved = provider
        moved.endpoint = "https://other.example/v1"
        #expect(reloaded.entry(providerID: provider.id, fingerprint: ProviderModelList.fingerprint(moved)) == nil)
        var rekeyed = provider
        rekeyed.apiKey = "other"
        #expect(ProviderModelList.fingerprint(rekeyed) == fingerprint)
        // The file holds neither the key nor the endpoint.
        let file = try String(
            contentsOf: directory.appendingPathComponent("providers/\(provider.id.uuidString)/models.json"),
            encoding: .utf8)
        #expect(!file.contains("synthetic") && !file.contains("openrouter"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("models.json").path))
    }

    @Test func disabledProvidersAreNeverChecked() async {
        // `.invalid` never resolves; the guard must reject before any request.
        for kind in ServiceProviderKind.allCases {
            var provider = ServiceProvider(kind: kind)
            provider.endpoint = "https://provider.invalid/v1"
            provider.apiKey = "synthetic"
            provider.isEnabled = false
            do {
                _ = try await ProviderConnectionChecker.check(provider)
                Issue.record("A disabled provider must not be checked")
            }
            catch {
                #expect(error.localizedDescription.contains("Enable This Provider"))
            }
        }
    }

    @Test func providerCachesKeepOtherDataAndDoNotLoadRootCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let models = ProviderMetadataCache<[ProviderModel]>(directory: directory, fileName: "models.json")
        let languages = ProviderMetadataCache<[String]>(directory: directory, fileName: "languages.json")
        languages.store(
            .init(providerID: id, fingerprint: "languages", value: ["en"], fetchedAt: Date()), keeping: [id])
        let entry = ProviderMetadataCache<[ProviderModel]>.Entry(
            providerID: id, fingerprint: "models", value: [.init(id: "model", name: nil)], fetchedAt: Date())
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("provider-models.json"))
        #expect(models.entry(providerID: id, fingerprint: "models") == nil)
        models.store(entry, keeping: [id])
        models.store(entry, keeping: [])
        let reopenedModels = ProviderMetadataCache<[ProviderModel]>(directory: directory, fileName: "models.json")
        let reopenedLanguages = ProviderMetadataCache<[String]>(directory: directory, fileName: "languages.json")
        #expect(reopenedModels.entry(providerID: id, fingerprint: "models") == nil)
        #expect(reopenedLanguages.entry(providerID: id, fingerprint: "languages")?.value == ["en"])
    }
}

@MainActor @Test func readOnlyLibraryGainsNoCacheFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ProviderMetadataCache<[ProviderModel]>(
        directory: directory, fileName: "models.json", canWrite: { false })
    let id = UUID()
    cache.store(.init(providerID: id, fingerprint: "f", value: [], fetchedAt: Date()), keeping: [id])
    #expect(cache.entry(providerID: id, fingerprint: "f") != nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("providers").path))
}
