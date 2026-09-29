import Foundation

struct ProviderLanguage: Codable, Equatable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}
struct ProviderLanguageCatalog: Codable, Equatable {
    let languages: [ProviderLanguage]
    let source: String
}
enum ProviderLanguageState: Equatable {
    /// No list has been loaded for the current configuration. Loading needs an explicit action.
    case idle
    /// The app ships this provider's list, so it is always available and never loaded.
    case builtIn(ProviderLanguageCatalog)
    case loading
    case loaded(ProviderLanguageCatalog, fetchedAt: Date)
    case failed(String)
}
/// Names the website whose languages a discovered list describes. Credentials and
/// enablement are excluded: they do not change the list, and the fingerprint is
/// stored on disk with the cached list.
struct ProviderLanguageIdentity: Hashable {
    let providerID: UUID
    let fingerprint: String
    init(provider: ServiceProvider) {
        providerID = provider.id
        fingerprint = ProviderMetadataCache<ProviderLanguageCatalog>.fingerprint([
            provider.kind.rawValue, provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), provider.model,
        ])
    }
}
@MainActor enum ProviderLanguageService {
    /// RunPod runs this repository's worker, so the app ships that worker's list
    /// (RunPodLanguages.swift) instead of starting a billable job to ask for it. A
    /// deployed worker that differs rejects the language when the job runs.
    nonisolated static func builtInCatalog(for provider: ServiceProvider) -> ProviderLanguageCatalog? {
        provider.kind == .runpod ? ProviderLanguageCatalog(languages: RunPodLanguages.all, source: provider.name) : nil
    }

    /// Discovers a list from providers without a built-in one. Only the Gday Meetings
    /// website supports discovery; its request is free.
    static func catalog(for provider: ServiceProvider) async throws -> ProviderResult<ProviderLanguageCatalog> {
        guard provider.supports(.transcription) else {
            throw ServiceError("Enable Transcription for this provider to load its languages.")
        }
        switch provider.kind {
        case .gdayWebsite:
            let server = GdayServerService.shared
            let origin = try ServiceHTTP.origin(provider.endpoint)
            guard server.connected,
                server.origin.flatMap(URL.init(string:)).map({ ServiceHTTP.sameOrigin($0, origin) }) == true
            else {
                throw ServiceError("Sign in to this Gday Meetings website to load its languages.")
            }
            return try await ProviderDataOperation.perform(
                target: provider.name, endpoint: provider.endpoint,
                bodies: ["language discovery"], purpose: "Load languages"
            ) {
                let response = try await ServiceHTTP.json(
                    server.authorizedRequest("api/platform/capabilities"),
                    trace: .init(provider: provider.name, data: "language list request"))
                guard response["protocolVersion"] as? Int == 1 else {
                    throw ServiceError(
                        "This website does not support language discovery. Update the Gday Meetings website.")
                }
                return try parseLanguages(response["transcriptionLanguages"], source: provider.name)
            }
        case .runpod:
            throw ServiceError("RunPod languages are built in and are not loaded.")
        case .openAICompatible, .filedrop:
            throw ServiceError("This provider does not support transcription.")
        }
    }

    nonisolated static func parseLanguages(_ value: Any?, source: String) throws -> ProviderLanguageCatalog {
        guard let entries = value as? [[String: Any]], !entries.isEmpty, entries.count <= 256 else {
            throw ServiceError("The provider did not report any transcription languages.")
        }
        var codes = Set<String>()
        var languages: [ProviderLanguage] = []
        for entry in entries {
            guard let code = entry["code"] as? String, let name = entry["name"] as? String,
                TranscriptionLanguage.isExplicit(code), code.count <= 40,
                code.range(of: "^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$", options: .regularExpression) != nil,
                !name.isEmpty, name.count <= 120, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                name.rangeOfCharacter(from: .controlCharacters) == nil,
                codes.insert(code.lowercased()).inserted
            else {
                throw ServiceError("The provider returned an invalid language list.")
            }
            languages.append(ProviderLanguage(code: code, name: name))
        }
        return ProviderLanguageCatalog(languages: languages, source: source)
    }
}
