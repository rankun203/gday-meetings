import Foundation
import Testing

@testable import GdayMeetings

struct LocalProviderConfigurationTests {
    @Test func localSpeakerProvidersDoNotRequireTranscriptionOrNetworkCredentials() {
        let live = ServiceProvider(kind: .speakerLabeling)
        let saved = ServiceProvider(kind: .speakerLabeling)
        #expect(live.supports(.liveDiarization))
        #expect(!live.supports(.transcription))
        #expect(!live.supports(.liveTranscription))
        #expect(saved.supports(.diarization))
        #expect(!saved.supports(.transcription))
        #expect(ProviderConfigurationEligibility.canSelect(live, for: .liveDiarization, providers: []))
        #expect(ProviderConfigurationEligibility.canSelect(saved, for: .diarization, providers: []))
        var unsupported = live
        unsupported.model = "unknown-model"
        #expect(!ProviderConfigurationEligibility.canSelect(unsupported, for: .liveDiarization, providers: []))
    }

    @Test func speakerDefaultsRoundTripIndependentlyAndOldSettingsStayOff() throws {
        var settings = AppSettings()
        var saved = ServiceProvider(kind: .speakerLabeling)
        saved.enabledCapabilities = []
        settings.serviceProviders = [saved]
        settings.transcriptionProviderID = UUID()
        settings.liveDiarizationProviderID = UUID()
        settings.diarizationProviderID = UUID()
        settings.showLiveSpeakerLabels = true
        settings.recognizeSpeakers = true
        settings.recognizeLiveSpeakers = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.transcriptionProviderID == settings.transcriptionProviderID)
        #expect(decoded.liveDiarizationProviderID == settings.liveDiarizationProviderID)
        #expect(decoded.diarizationProviderID == settings.diarizationProviderID)
        #expect(decoded.showLiveSpeakerLabels && decoded.recognizeSpeakers)
        #expect(!decoded.recognizeLiveSpeakers)
        settings.recognizeSpeakers = false
        settings.recognizeLiveSpeakers = true
        let liveOnly = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(liveOnly.recognizeLiveSpeakers && !liveOnly.recognizeSpeakers)
        #expect(decoded.serviceProviders == settings.serviceProviders)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!old.showLiveSpeakerLabels && !old.recognizeSpeakers && !old.recognizeLiveSpeakers)
        #expect(old.liveDiarizationProviderID == nil && old.diarizationProviderID == nil)
    }

    @Test func everyCatalogPresetCanBeConfiguredBeforeDownload() throws {
        for model in LocalModelID.allCases where model.nemotronPreset != nil {
            var provider = ServiceProvider(kind: .speakerLabeling)
            provider.model = model.rawValue
            #expect(ProviderConfigurationEligibility.canSelect(provider, for: .liveDiarization, providers: []))
            let restored = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
            #expect(restored.model == model.rawValue)
            #expect(restored.endpoint.isEmpty && restored.apiKey.isEmpty)
        }
    }

    @MainActor @Test func savedLabelingRequiresSelectedEnabledCapability() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalProviderTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        var meeting = Meeting(title: "Synthetic speaker check")
        meeting.transcript = [TranscriptSegment(start: 0, end: 1, speaker: "", text: "Example passage")]
        try await store.insertImportedMeeting(meeting)
        var disabled = ServiceProvider(kind: .speakerLabeling)
        disabled.isEnabled = false
        var labelsOff = ServiceProvider(kind: .speakerLabeling)
        labelsOff.enabledCapabilities = []
        for provider in [nil, disabled, labelsOff, ServiceProvider(kind: .openAICompatible)] {
            store.settings.serviceProviders = provider.map { [$0] } ?? []
            store.settings.diarizationProviderID = provider?.id
            await store.diarizeLocally(id: meeting.id)
            #expect(!store.isJobRunning(.diarization, .meeting(meeting.id)))
            #expect(!store.managedTasks.contains { $0.meetingID == meeting.id && $0.kind == .diarization })
            #expect(store.meeting(id: meeting.id)?.transcript == meeting.transcript)
        }
    }
}

extension LocalProviderConfigurationTests {
    @Test func unifiedLiveControlsPreserveLabelingAndRespectAssociationMigration() throws {
        for (json, enabled) in [
            ("{\"showLiveSpeakerLabels\":true}", true), ("{\"recognizeLiveSpeakers\":true}", false),
        ] {
            var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.liveSpeakerRecognitionEnabled == enabled)
            #expect(!settings.recognizeSpeakers)
            let untouched = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(untouched == settings)
            settings.liveSpeakerRecognitionEnabled = false
            #expect(!settings.showLiveSpeakerLabels && !settings.recognizeLiveSpeakers)
            settings.liveSpeakerRecognitionEnabled = true
            #expect(settings.showLiveSpeakerLabels && settings.recognizeLiveSpeakers)
            let updated = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(updated.liveSpeakerRecognitionEnabled)
            #expect(!updated.recognizeSpeakers)
        }
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!old.liveSpeakerRecognitionEnabled)
    }
}
