import Foundation
import Testing

@testable import GdayMeetings

struct AutomaticTranscriptionTests {
    @Test(arguments: [
        (false, false, false, false), (false, false, true, false),
        (false, true, false, false), (false, true, true, false),
        (true, false, false, true), (true, false, true, false),
        (true, true, false, true), (true, true, true, true),
    ])
    func finalizedTextPolicy(automatic: Bool, override: Bool, finalized: Bool, expected: Bool) {
        var settings = AppSettings()
        settings.autoTranscribe = automatic
        settings.autoTranscribeEvenWithLiveTranscript = override
        #expect(
            settings.shouldAutomaticallyTranscribe(hasUsableFinalizedLiveTranscript: finalized)
                == expected)
    }

    @Test func olderSettingsKeepAutomaticChoiceWithoutLiveOverride() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoTranscribe":true}"#.utf8))
        #expect(settings.autoTranscribe)
        #expect(!settings.autoTranscribeEvenWithLiveTranscript)
        #expect(settings.shouldAutomaticallyTranscribe(hasUsableFinalizedLiveTranscript: false))
        #expect(!settings.shouldAutomaticallyTranscribe(hasUsableFinalizedLiveTranscript: true))
    }

    @Test func overrideSurvivesSettingsRoundTripWhileAutomaticIsOff() throws {
        var settings = AppSettings()
        settings.autoTranscribeEvenWithLiveTranscript = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        #expect(!restored.shouldAutomaticallyTranscribe(hasUsableFinalizedLiveTranscript: true))
    }
}
