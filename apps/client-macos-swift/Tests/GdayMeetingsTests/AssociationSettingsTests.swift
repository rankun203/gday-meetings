import Foundation
import Testing

@testable import GdayMeetings

struct AssociationSettingsTests {
    @Test(arguments: [true, false]) func oldProvidersMergeWithoutLosingSelectionsOrQueuedJobIDs(recordedEnabled: Bool)
        throws
    {
        var live = ServiceProvider(kind: .speakerLabeling)
        live.model = "nemotronFast"
        var recorded = ServiceProvider(kind: .speakerLabeling)
        recorded.isEnabled = recordedEnabled
        var settings = AppSettings()
        settings.serviceProviders = [live, recorded]
        settings.liveDiarizationProviderID = live.id
        settings.diarizationProviderID = recorded.id
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var providers = try #require(object["serviceProviders"] as? [[String: Any]])
        providers[0]["kind"] = "nemotron"
        providers[0]["enabledCapabilities"] = ["liveDiarization", "speakerRecognition"]
        providers[1]["kind"] = "community1"
        providers[1]["model"] = "community1"
        providers[1]["enabledCapabilities"] = ["diarization", "speakerRecognition"]
        object["serviceProviders"] = providers
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.serviceProviders.count == 1)
        let unified = try #require(restored.serviceProviders.first)
        #expect(unified.kind == .speakerLabeling && unified.model == "nemotronFast")
        #expect(unified.supports(.liveDiarization))
        #expect(unified.supports(.diarization) == recordedEnabled)
        #expect(restored.liveDiarizationProviderID == live.id)
        #expect(restored.diarizationProviderID == live.id)
        #expect(restored.resolvedSpeakerProviderID(recorded.id) == live.id)
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored))
        #expect(reopened == restored)
    }

    @Test func associationDoesNotRequireAProviderSelection() throws {
        var settings = AppSettings()
        settings.serviceProviders = []
        settings.recognizeSpeakers = true
        settings.recognizeLiveSpeakers = true
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(restored.recognizeSpeakers && restored.recognizeLiveSpeakers)
        #expect(!String(decoding: data, as: UTF8.self).contains("speakerRecognitionProviderID"))
        #expect(!ProviderCapability.allCases.map(\.rawValue).contains("speakerRecognition"))
        #expect(ServiceProviderKind.speakerLabeling.capabilities == [.liveDiarization, .diarization])
    }

    @Test(arguments: [true, false]) func legacySelectionPreservesEffectiveOptIn(enabled: Bool) throws {
        let provider = ServiceProvider(kind: .speakerLabeling)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        settings.recognizeSpeakers = true
        settings.recognizeLiveSpeakers = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "associationSettingsVersion")
        object["speakerRecognitionProviderID"] = provider.id.uuidString
        object["initializedProviderCapabilities"] = ["speakerRecognition", "diarization"]
        var providers = try #require(object["serviceProviders"] as? [[String: Any]])
        providers[0]["enabledCapabilities"] = enabled ? ["diarization", "speakerRecognition"] : ["diarization"]
        object["serviceProviders"] = providers
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.recognizeSpeakers == enabled)
        #expect(restored.recognizeLiveSpeakers == enabled)
        #expect(restored.serviceProviders[0].enabledCapabilities == [.diarization])
        #expect(restored.initializedProviderCapabilities == [.diarization])
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored))
        #expect(reopened.recognizeSpeakers == enabled)
    }

    @Test func providerReadinessDoesNotEnableAssociation() {
        var settings = AppSettings()
        settings.assignInitiallyHealthyProvider(UUID(), capabilities: [.diarization, .liveDiarization])
        #expect(settings.labelRecordedSpeakers && settings.showLiveSpeakerLabels)
        #expect(!settings.recognizeSpeakers && !settings.recognizeLiveSpeakers)
    }
}
