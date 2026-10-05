import Foundation

/// Configuration requirements for choosing task defaults. Connection status is
/// checked separately and never prevents saving a provider for later setup.
enum ProviderConfigurationEligibility {
    static func canSelect(
        _ provider: ServiceProvider, for capability: ProviderCapability, providers: [ServiceProvider]
    ) -> Bool {
        guard provider.supports(capability), hasText(provider.name) else { return false }
        if provider.kind == .localSearch {
            return provider.localSearch?.executableURL?.isFileURL == true
                && provider.localSearch?.modelCacheURL?.isFileURL == true
        }
        if provider.kind.isLocalSpeaker {
            if capability == .speakerRecognition { return true }
            switch provider.kind {
            case .nemotron:
                return LocalModelID.allCases.contains {
                    $0.rawValue.hasPrefix("nemotron") && $0.rawValue == provider.model
                }
            case .community1: return provider.model == "community1"
            default: return false
            }
        }
        guard
            (try? ProviderEndpoint.base(provider.endpoint)) != nil
        else { return false }
        switch provider.kind {
        case .nemotron, .community1, .localSearch: return false
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
