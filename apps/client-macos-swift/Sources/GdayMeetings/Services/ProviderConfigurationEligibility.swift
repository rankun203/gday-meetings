import Foundation

/// Configuration requirements for choosing task defaults. Connection status is
/// checked separately and never prevents saving a provider for later setup.
enum ProviderConfigurationEligibility {
    static func canSelect(
        _ provider: ServiceProvider, for capability: ProviderCapability, providers: [ServiceProvider]
    ) -> Bool {
        guard provider.supports(capability), hasText(provider.name) else { return false }
        if provider.kind == .localSearch || provider.kind == .appleSpeech {
            return true
        }
        if provider.kind.isLocalSpeaker {
            return capability == .diarization
        }
        guard
            (try? ProviderEndpoint.base(provider.endpoint)) != nil
        else { return false }
        switch provider.kind {
        case .speakerLabeling, .localSearch, .appleSpeech: return false
        case .runpod:
            guard (try? ProviderEndpoint.runpod(provider.endpoint)) != nil,
                hasText(provider.apiKey)
            else { return false }
            return providers.contains {
                $0.id == provider.uploadProviderID && $0.kind == .filedrop
                    && canSelect($0, for: .fileTransfer, providers: [])
            }
        case .filedrop:
            return hasText(provider.apiKey)
        case .openAICompatible:
            // Local compatible services can accept requests without an API key.
            return hasText(provider.model)
        case .gdayWebsite:
            return true
        }
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
