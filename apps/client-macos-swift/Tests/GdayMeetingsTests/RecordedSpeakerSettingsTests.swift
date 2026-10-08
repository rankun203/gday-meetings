import Foundation
import Testing

@testable import GdayMeetings

struct RecordedSpeakerSettingsTests {
    @Test func freshSettingsEnableOnlyLocalRecordedDiarization() throws {
        let settings = AppSettings()
        let provider = try #require(settings.serviceProviders.first { $0.id == settings.diarizationProviderID })
        #expect(settings.labelRecordedSpeakers)
        #expect(!settings.recognizeSpeakers)
        #expect(provider.kind == .speakerLabeling)
        #expect(provider.model == "community1")
        #expect(provider.kind.title == "Speaker Diarization")
        #expect(provider.enabledCapabilities == [.diarization])
        #expect(ProviderCapability.allCases.allSatisfy { $0.rawValue != "liveDiarization" })
    }

    @Test func newAutomaticDiarizationPreferenceDefaultsOnAndPersistsOff() throws {
        var settings = try JSONDecoder().decode(
            AppSettings.self, from: Data("{\"labelRecordedSpeakers\":false}".utf8))
        #expect(settings.labelRecordedSpeakers)
        settings.labelRecordedSpeakers = false
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["autoDiarize"] as? Bool == false)
        #expect(object["labelRecordedSpeakers"] == nil)
        let reopened = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(!reopened.labelRecordedSpeakers)
    }

    @Test func missingDefaultsSelectLocalInsteadOfConfiguredRemote() throws {
        var object: [String: Any] = [:]
        let remote = ServiceProvider(kind: .runpod)
        object["serviceProviders"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([remote]))
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        let provider = try #require(settings.serviceProviders.first { $0.id == settings.diarizationProviderID })
        #expect(settings.labelRecordedSpeakers)
        #expect(provider.kind == .speakerLabeling)
        #expect(provider.id != remote.id)
    }

    @Test(arguments: [true, false])
    func oldSpeakerPreferencesDoNotActivateRemoteUploads(selectedRemote: Bool) throws {
        let remote = ServiceProvider(kind: .runpod)
        let providers = try JSONSerialization.jsonObject(with: JSONEncoder().encode([remote]))
        let object: [String: Any] = [
            "serviceProviders": providers,
            "labelRecordedSpeakers": false,
            "diarizationProviderID": selectedRemote ? remote.id.uuidString as Any : NSNull(),
            "initializedProviderCapabilities": ["diarization"],
        ]
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        let selected = try #require(settings.serviceProviders.first { $0.id == settings.diarizationProviderID })
        #expect(settings.labelRecordedSpeakers)
        #expect(selected.kind == .speakerLabeling)
        #expect(selected.id != remote.id)
        #expect(!settings.shouldLabelDuringTranscription(providerID: remote.id))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["diarizationProviderID"] == nil)
        #expect(encoded["speakerDiarizationProviderID"] as? String == selected.id.uuidString)
    }

    @Test func explicitNoneAndDisabledLabelingSurviveRepeatedOpenAndReadiness() throws {
        var settings = AppSettings()
        settings.selectProvider(nil, for: .diarization)
        settings.labelRecordedSpeakers = false
        settings.recordExplicitFeatureChoice(\.labelRecordedSpeakers, enabled: false)
        for _ in 0..<3 {
            settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            let changed = settings.assignInitiallyHealthyProvider(UUID(), capabilities: [.diarization])
            #expect(!changed)
            #expect(settings.diarizationProviderID == nil)
            #expect(!settings.labelRecordedSpeakers)
        }
    }

    @Test func explicitRecordedAssociationAndProviderRemainIndependent() throws {
        var settings = AppSettings()
        let remote = ServiceProvider(kind: .runpod)
        settings.serviceProviders = [remote]
        settings.selectProvider(remote.id, for: .diarization)
        settings.recognizeSpeakers = true
        settings.labelRecordedSpeakers = false
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(reopened.diarizationProviderID == remote.id)
        #expect(reopened.recognizeSpeakers)
        #expect(!reopened.labelRecordedSpeakers)
        let data = try JSONEncoder().encode(reopened)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["showLiveSpeakerLabels"] == nil)
        #expect(object["recognizeLiveSpeakers"] == nil)
        #expect(object["liveDiarizationProviderID"] == nil)
    }
}
