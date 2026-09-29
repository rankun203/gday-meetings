import Foundation

extension MeetingStore {
    func languageIdentity(for providerID: UUID?) -> ProviderLanguageIdentity? {
        guard let provider = settings.serviceProviders.first(where: { $0.id == providerID }) else { return nil }
        return ProviderLanguageIdentity(provider: provider)
    }

    /// Reads built-in or cached provider support only; never sends a request.
    func languageState(for providerID: UUID?) -> ProviderLanguageState {
        guard let provider = settings.serviceProviders.first(where: { $0.id == providerID }) else { return .idle }
        if let catalog = ProviderLanguageService.builtInCatalog(for: provider) { return .builtIn(catalog) }
        let identity = ProviderLanguageIdentity(provider: provider)
        if let transient = providerLanguageStates[identity] { return transient }
        if let entry = cachedLanguages(identity) {
            return .loaded(entry.value, fetchedAt: entry.fetchedAt)
        }
        return .idle
    }

    private func cachedLanguages(_ identity: ProviderLanguageIdentity)
        -> ProviderMetadataCache<ProviderLanguageCatalog>.Entry?
    {
        providerLanguageCache.entry(providerID: identity.providerID, fingerprint: identity.fingerprint)
    }

    /// Loads the provider's current list when the person chooses Load Languages.
    /// Providers with a built-in list are never asked.
    func refreshProviderLanguages(providerID: UUID?) async {
        guard let provider = settings.serviceProviders.first(where: { $0.id == providerID }),
            ProviderLanguageService.builtInCatalog(for: provider) == nil
        else { return }
        _ = try? await resolveProviderLanguages(provider, refresh: true)
    }

    private func resolveProviderLanguages(_ provider: ServiceProvider, refresh: Bool) async throws
        -> ProviderLanguageCatalog
    {
        guard let identity = languageIdentity(for: provider.id),
            settings.serviceProviders.first(where: { $0.id == provider.id }) == provider
        else {
            throw ServiceError("The provider settings changed. Load its languages again.")
        }
        if !refresh, let entry = cachedLanguages(identity) {
            return entry.value
        }
        if let task = providerLanguageTasks[identity] {
            let catalog = try await task.value.value
            guard languageIdentity(for: provider.id) == identity else {
                throw ServiceError("The provider settings changed. Load its languages again.")
            }
            return catalog
        }
        providerLanguageStates = providerLanguageStates.filter { $0.key.providerID != provider.id }
        providerLanguageStates[identity] = .loading
        let loader = providerLanguageLoader
        let task = Task { try await loader(provider) }
        providerLanguageTasks[identity] = task
        defer { providerLanguageTasks.removeValue(forKey: identity) }
        do {
            let catalog = try await task.value.value
            guard languageIdentity(for: provider.id) == identity else {
                providerLanguageStates.removeValue(forKey: identity)
                throw ServiceError("The provider settings changed. Load its languages again.")
            }
            providerLanguageCache.store(
                .init(
                    providerID: identity.providerID, fingerprint: identity.fingerprint, value: catalog,
                    fetchedAt: Date()),
                // Entries saved for RunPod before its list was built in are dropped here.
                keeping: Set(
                    settings.serviceProviders.filter { ProviderLanguageService.builtInCatalog(for: $0) == nil }
                        .map(\.id)))
            providerLanguageStates.removeValue(forKey: identity)
            return catalog
        }
        catch {
            if languageIdentity(for: provider.id) == identity {
                providerLanguageStates[identity] = .failed(error.localizedDescription)
            }
            else {
                providerLanguageStates.removeValue(forKey: identity)
            }
            throw error
        }
    }

    /// Resolves the app choice before audio is uploaded. Website discovery is
    /// metadata-only and happens only for an explicit transcription or refresh.
    func resolvedTranscriptionLanguage(
        _ language: String, for provider: ServiceProvider,
        preservingRequestCode: Bool = false
    ) async throws -> String {
        try TranscriptionLanguage.validate(language)
        let catalog: ProviderLanguageCatalog
        if let builtIn = ProviderLanguageService.builtInCatalog(for: provider) {
            catalog = builtIn
        }
        else {
            catalog = try await resolveProviderLanguages(provider, refresh: false)
        }
        let code =
            preservingRequestCode
            ? catalog.languages.first { $0.code == language }?.code
            : AppLanguages.providerCode(for: language, catalog: catalog)
        guard let code else {
            throw ServiceError(
                "\(provider.name) does not support \(AppLanguages.name(for: language)). Choose another transcription provider or change the meeting language."
            )
        }
        return code
    }
    func validateTranscriptionLanguage(_ language: String, for provider: ServiceProvider) async throws {
        _ = try await resolvedTranscriptionLanguage(language, for: provider)
    }
}
