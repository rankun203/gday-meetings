import Foundation

extension AppSettings {
    mutating func recordExplicitFeatureChoice(_ keyPath: WritableKeyPath<AppSettings, Bool>, enabled: Bool) {
        guard let name = Self.featureNames[keyPath] else { return }
        if enabled {
            explicitlyDisabledFeatures.remove(name)
        }
        else {
            explicitlyDisabledFeatures.insert(name)
        }
    }

    private static var featureNames: [WritableKeyPath<AppSettings, Bool>: String] {
        [
            \.showLiveTranscript: "liveTranscription", \.showLiveSpeakerLabels: "liveLabeling",
            \.recognizeLiveSpeakers: "liveAssociation", \.labelRecordedSpeakers: "recordedLabeling",
            \.recognizeSpeakers: "recordedAssociation", \.autoTranscribe: "recordedTranscription",
            \.autoSummarize: "summary", \.autoExtractTodos: "todos",
        ]
    }

    private mutating func enableInitially(_ keyPath: WritableKeyPath<AppSettings, Bool>) {
        guard let name = Self.featureNames[keyPath], !explicitlyDisabledFeatures.contains(name) else { return }
        self[keyPath: keyPath] = true
    }

    func selectedProvider(for capability: ProviderCapability) -> UUID? {
        switch capability {
        case .liveTranscription: liveTranscriptionProviderID
        case .transcription: transcriptionProviderID
        case .liveDiarization: liveDiarizationProviderID
        case .diarization: diarizationProviderID
        case .summarization: summaryProviderID
        case .search: searchProviderID
        default: nil
        }
    }

    /// Explicit selections, including None, must survive later provider checks.
    mutating func selectProvider(_ id: UUID?, for capability: ProviderCapability) {
        if id != nil, selectedProvider(for: capability) == nil,
            !initializedProviderCapabilities.contains(capability)
        {
            enableInitialFeatures(for: capability)
        }
        initializedProviderCapabilities.insert(capability)
        switch capability {
        case .liveTranscription: liveTranscriptionProviderID = id
        case .transcription: transcriptionProviderID = id
        case .liveDiarization: liveDiarizationProviderID = id
        case .diarization: diarizationProviderID = id
        case .summarization: summaryProviderID = id
        case .search: searchProviderID = id
        default: break
        }
    }

    @discardableResult
    mutating func assignInitiallyHealthyProvider(_ id: UUID, capabilities: Set<ProviderCapability>) -> Bool {
        var changed = false
        for capability in capabilities {
            guard selectedProvider(for: capability) == nil,
                !initializedProviderCapabilities.contains(capability)
            else { continue }
            guard
                [
                    .liveTranscription, .transcription, .liveDiarization, .diarization,
                    .summarization,
                ].contains(capability)
            else { continue }
            selectProvider(id, for: capability)
            changed = true
        }
        return changed
    }

    private mutating func enableInitialFeatures(for capability: ProviderCapability) {
        switch capability {
        case .liveTranscription: enableInitially(\.showLiveTranscript)
        case .transcription: enableInitially(\.autoTranscribe)
        case .liveDiarization: enableInitially(\.showLiveSpeakerLabels)
        case .diarization: enableInitially(\.labelRecordedSpeakers)
        case .summarization:
            enableInitially(\.autoSummarize)
            enableInitially(\.autoExtractTodos)
        default: break
        }
    }

    func shouldLabelDuringTranscription(providerID: UUID) -> Bool {
        labelRecordedSpeakers && diarizationProviderID == providerID
    }
}
