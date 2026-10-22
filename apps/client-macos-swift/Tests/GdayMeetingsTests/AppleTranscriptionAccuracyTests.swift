import Foundation
import Speech
import Testing

@testable import GdayMeetings

struct AppleTranscriptionAccuracyTests {
    @Test func existingSettingsKeepFastLiveResults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!settings.thisMacFavorAccuracy)
        #expect(!AppSettings().thisMacFavorAccuracy)
    }

    @Test(arguments: [false, true])
    func preferenceSurvivesReload(_ enabled: Bool) throws {
        var settings = AppSettings()
        settings.thisMacFavorAccuracy = enabled
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).thisMacFavorAccuracy == enabled)
    }

    @Test(arguments: [false, true])
    func accuracyPreservesLiveUpdatesAndTiming(_ enabled: Bool) {
        let preset = AppleLiveTranscription.preset(favorAccuracy: enabled)
        #expect(preset.reportingOptions.contains(.fastResults) == !enabled)
        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(preset.attributeOptions.contains(.audioTimeRange))
        #expect(
            preset.transcriptionOptions
                == SpeechTranscriber.Preset.timeIndexedProgressiveTranscription.transcriptionOptions)
    }
}
