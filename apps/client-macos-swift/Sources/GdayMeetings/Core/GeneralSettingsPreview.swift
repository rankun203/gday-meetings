import Foundation

extension UIPreview {
    /// Ten deterministic states for General. Seeded health never contacts a service.
    static var generalScenario: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        let argument = arguments.first { $0.hasPrefix("--general-scenario=") }
        return
            argument.flatMap { Int($0.split(separator: "=").last ?? "") }
            ?? Bundle.main.object(forInfoDictionaryKey: "GdayGeneralScenario") as? Int
    }

    @MainActor static func configureGeneralScenario(_ store: MeetingStore, scenario: Int? = generalScenario) {
        guard enabled, let scenario, (1...10).contains(scenario) else { return }
        var settings = syntheticProviderSettings(AppSettings())
        let speakers = ServiceProvider(kind: .speakerLabeling)
        settings.serviceProviders.append(speakers)
        settings.liveTranscriptionProviderID = ThisMacProvider.id
        settings.diarizationProviderID = speakers.id
        settings.showLiveTranscript = true
        settings.labelRecordedSpeakers = true
        settings.recognizeSpeakers = true
        settings.autoSummarize = true
        settings.autoExtractTodos = true
        let health = ProviderHealthStore.shared
        health.seed(providerID: ThisMacProvider.id, capability: .liveTranscription, health: .ready)
        for provider in settings.serviceProviders {
            for capability in provider.kind.capabilities {
                health.seed(providerID: provider.id, capability: capability, health: .ready)
            }
        }
        switch scenario {
        case 1: break  // All features and providers are ready.
        case 2:
            settings.showLiveTranscript = false
            settings.autoTranscribe = false
            settings.labelRecordedSpeakers = false
            settings.recognizeSpeakers = false
            settings.autoSummarize = false
            settings.autoExtractTodos = false
        case 3:
            settings.liveTranscriptionProviderID = nil
        case 4:
            health.seed(
                providerID: speakers.id, capability: .diarization,
                health: .notReady("Required files are missing."))
        case 5:
            health.seed(providerID: ThisMacProvider.id, capability: .liveTranscription, health: .checking)
            health.seed(providerID: speakers.id, capability: .diarization, health: .checking)
        case 6:
            health.seed(
                providerID: speakers.id, capability: .diarization,
                health: .notReady("Provider is turned off."))
        case 7:
            health.seed(
                providerID: speakers.id, capability: .diarization,
                health: .notReady("Required files are missing."))
        case 8:
            health.seed(
                providerID: settings.transcriptionProviderID!, capability: .transcription,
                health: .unknown("The server did not respond."))
        case 9:
            settings.autoTranscribe = false
            settings.labelRecordedSpeakers = false
            settings.recognizeSpeakers = false
            settings.autoExtractTodos = false
        case 10:
            health.seed(
                providerID: ThisMacProvider.id, capability: .liveTranscription,
                health: .notReady("Choose a supported transcription language."))
        default: break
        }
        store.settings = settings
    }
}
