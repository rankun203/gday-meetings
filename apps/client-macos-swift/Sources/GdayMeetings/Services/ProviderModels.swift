import Foundation

struct ProviderModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String?
    var inputModalities: [String]? = nil
}

/// Reads an OpenAI-compatible `GET {endpoint}/models` list. The request sends only
/// the API key; it is free metadata and starts no work at the provider.
enum ProviderModelList {
    static let maximumModels = 5_000

    /// The list depends on the endpoint only. Keys are excluded so the cache file
    /// holds no credential-derived value.
    static func fingerprint(_ provider: ServiceProvider) -> String {
        ProviderMetadataCache<[ProviderModel]>.fingerprint([
            provider.kind.rawValue, provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    static func request(_ provider: ServiceProvider) throws -> URLRequest {
        let url = try ProviderEndpoint.base(provider.endpoint).appendingPathComponent("models")
        return ProviderEndpoint.authorized(url, key: provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fetch(_ provider: ServiceProvider) async throws -> ProviderResult<[ProviderModel]> {
        try await ProviderDataOperation.perform(
            target: provider.name, endpoint: provider.endpoint,
            bodies: ["model discovery"], purpose: "Load models"
        ) {
            let response = try await ServiceHTTP.json(
                request(provider), trace: .init(provider: provider.name, data: "model list"))
            return try parse(response)
        }
    }

    /// Skips malformed entries instead of rejecting the list: compatible servers vary,
    /// and the Model field accepts any typed name anyway.
    static func parse(_ response: [String: Any]) throws -> [ProviderModel] {
        guard let entries = response["data"] as? [[String: Any]] else {
            throw ServiceError("This endpoint did not return a model list.")
        }
        var seen = Set<String>()
        var models: [ProviderModel] = []
        for entry in entries.prefix(maximumModels) {
            guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 200,
                id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                id.rangeOfCharacter(from: .controlCharacters) == nil, seen.insert(id).inserted
            else { continue }
            let name = (entry["name"] as? String).flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed.count > 200 || trimmed == id ? nil : trimmed
            }
            let architecture = entry["architecture"] as? [String: Any]
            let modalities = architecture?["input_modalities"] as? [String]
            models.append(ProviderModel(id: id, name: name, inputModalities: modalities))
        }
        guard !models.isEmpty else { throw ServiceError("This endpoint returned an empty model list.") }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Case-insensitive match on ID or name. An empty query or an exact ID shows every model,
    /// so reopening the menu after choosing a model still offers the full list.
    static func filter(_ models: [ProviderModel], query: String) -> [ProviderModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !models.contains(where: { $0.id == query }) else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

/// When the provider panel may list models automatically. Listing is free
/// metadata, so it may run without a button, but never for a disabled provider
/// unless the person is entering that provider's endpoint or key.
enum ProviderModelListPolicy {
    enum Plan: Equatable {
        case none
        /// The saved configuration of an enabled provider: list on open.
        case immediate
        /// Fields are being edited: wait for typing to pause.
        case debounced
    }
    static let debounce: Duration = .milliseconds(800)

    static func plan(draft: ServiceProvider, saved: ServiceProvider?) -> Plan {
        guard draft.kind == .openAICompatible,
            !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (try? ProviderEndpoint.base(draft.endpoint)) != nil
        else { return .none }
        let editing = saved.map { draft.endpoint != $0.endpoint || draft.apiKey != $0.apiKey } ?? true
        if editing { return .debounced }
        return draft.isEnabled ? .immediate : .none
    }
}
