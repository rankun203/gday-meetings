import Foundation
import Testing

@testable import GdayMeetings

struct LiveSharedSpeakerIndexTests {
    @Test func cachedSharedVoiceUsesOnlyItsOwnSourceActivityAndRefreshesMembership() {
        let generation = UUID()
        var speaker = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "synthetic", revision: "1")
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [speaker]
        timeline.cursors = LiveAudioSource.allCases.map {
            .init(source: $0, generation: generation, sequence: 0, end: 10, final: false)
        }
        timeline.intervals = [
            .init(source: .microphone, speakerID: speaker.id, start: 0, end: 3),
            .init(source: .system, speakerID: speaker.id, start: 5, end: 8),
        ]
        let system = LiveTranscriptPhrase(session: UUID(), source: .system, start: 5, end: 8, text: "System voice")
        var index = LiveSpeakerIntervalIndex(timeline)
        #expect(index.evidence(for: system, preceding: nil).attributing(system).first?.speakerIdentity == nil)
        speaker.additionalSources = [.system]
        timeline.speakers = [speaker]
        index.update(timeline)
        #expect(index.evidence(for: system, preceding: nil).attributing(system).first?.speakerIdentity == speaker.id)
        let earlySystem = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 3, text: "No system activity")
        let lateMic = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 5, end: 8, text: "No mic activity")
        for phrase in [earlySystem, lateMic] {
            #expect(index.evidence(for: phrase, preceding: nil).attributing(phrase).first?.speakerIdentity == nil)
        }
        let person = UUID()
        timeline.speakers[0].personID = person
        index.update(timeline)
        #expect(index.evidence(for: system, preceding: nil).attributing(system).first?.personID == person)
        timeline.speakers[0].additionalSources = nil
        index.update(timeline)
        #expect(index.evidence(for: system, preceding: nil).attributing(system).first?.speakerIdentity == nil)
    }

    @Test func resolutionCacheMatchesDirectSourceScopedAttribution() {
        let generation = UUID()
        let speaker = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "synthetic", revision: "1", additionalSources: [.system])
        var timeline = LiveSpeakerTimeline(speakers: [speaker])
        timeline.cursors = LiveAudioSource.allCases.map {
            .init(source: $0, generation: generation, sequence: 0, end: 10, final: false)
        }
        timeline.intervals = [
            .init(source: .microphone, speakerID: speaker.id, start: 0, end: 3),
            .init(source: .system, speakerID: speaker.id, start: 5, end: 8),
        ]
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.speakerTimeline = timeline
        draft.phrases = [.init(session: UUID(), source: .system, start: 5, end: 8, text: "System")]
        let cache = LiveTranscriptResolutionCache()
        let expected = timeline.attributing(draft.phrases[0]).map { phrase in
            var value = phrase
            value.recognizedFinal = true
            return value
        }
        #expect(draft.resolvedRows(cache: cache).finalized == expected)
        #expect(draft.resolvedRows(cache: cache).finalized.first?.speakerIdentity == speaker.id)
    }
}
