import Foundation
import Testing

@testable import GdayMeetings

struct VoiceDetectedSpeakerScopeTests {
    @Test func retainsFullDetectedScopeWithoutOtherTracksOrUncertainTurns() {
        let speaker = MeetingSpeaker(label: "voice_a", track: "track0", providerName: "Synthetic")
        let result = LocalDiarizationResult(
            modelRevision: "synthetic-v1",
            ranges: [
                .init(track: "track0", label: "voice_a", start: 20, end: 30),
                .init(track: "track0", label: "voice_a", start: 0, end: 12),
                .init(track: "track0", label: "voice_a", start: 10, end: 15),
                .init(track: "track1", label: "voice_a", start: 40, end: 50),
                .init(track: "track0", label: "voice_b", start: 50, end: 60),
                .init(track: "track0", label: "voice_a", start: 60, end: 70, associationUncertain: true),
                .init(track: "track0", label: "voice_a", start: 80, end: 75),
            ], speakers: [speaker])
        #expect(
            VoiceDetectedSpeakerScope.spans(speaker: speaker, analysis: result) == [
                SpeakerEvidenceSpan(start: 0, end: 15), SpeakerEvidenceSpan(start: 20, end: 30),
            ])
        var changed = result
        changed.modelRevision = "synthetic-v2"
        #expect(
            VoiceDetectedSpeakerScope.identity(speaker: speaker, analysis: result)
                != VoiceDetectedSpeakerScope.identity(speaker: speaker, analysis: changed))
    }

    @Test func missingTurnsCannotInventScope() {
        let speaker = MeetingSpeaker(label: "voice_a", track: "track0", providerName: "Synthetic")
        let result = LocalDiarizationResult(modelRevision: "synthetic-v1", ranges: [], speakers: [speaker])
        #expect(VoiceDetectedSpeakerScope.spans(speaker: speaker, analysis: result) == nil)
    }
}
