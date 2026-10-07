import Foundation

extension AppSettings {
    func resolvedSpeakerProviderID(_ id: UUID?) -> UUID? {
        id.map { speakerProviderAliases[$0] ?? $0 }
    }

    /// Merge old live and recorded configurations while retaining queued-job references.
    mutating func consolidateSpeakerProviders() {
        let providers = serviceProviders.filter { $0.kind == .speakerLabeling }
        guard providers.count > 1 else { return }
        var merged =
            providers.first { $0.id == liveDiarizationProviderID }
            ?? providers.first { $0.id == diarizationProviderID } ?? providers[0]
        let live =
            providers.first { $0.id == liveDiarizationProviderID }
            ?? providers.first { $0.enabledCapabilities.contains(.liveDiarization) }
        if let live { merged.model = live.model }
        let recorded =
            providers.first { $0.id == diarizationProviderID }
            ?? providers.first { $0.enabledCapabilities.contains(.diarization) }
        merged.name = "Speaker Labeling"
        merged.enabledCapabilities = []
        if live?.supports(.liveDiarization) == true { merged.enabledCapabilities.insert(.liveDiarization) }
        if recorded?.supports(.diarization) == true { merged.enabledCapabilities.insert(.diarization) }
        merged.isEnabled = providers.contains { $0.isEnabled }
        let retired = Set(providers.map(\.id)).subtracting([merged.id])
        for key in speakerProviderAliases.keys where retired.contains(speakerProviderAliases[key]!) {
            speakerProviderAliases[key] = merged.id
        }
        for id in retired { speakerProviderAliases[id] = merged.id }
        liveDiarizationProviderID = resolvedSpeakerProviderID(liveDiarizationProviderID)
        diarizationProviderID = resolvedSpeakerProviderID(diarizationProviderID)
        serviceProviders.removeAll { retired.contains($0.id) }
        if let index = serviceProviders.firstIndex(where: { $0.id == merged.id }) { serviceProviders[index] = merged }
    }
}
