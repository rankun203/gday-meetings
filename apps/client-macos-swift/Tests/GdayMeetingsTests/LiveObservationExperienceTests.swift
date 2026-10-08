import Foundation
import Testing

@testable import GdayMeetings

struct LiveObservationExperienceTests {
    private func speaker(_ slot: Int = 0) -> LiveSpeakerIdentity {
        .init(
            id: UUID(), source: .microphone, generation: UUID(), slot: slot,
            model: "fixture", revision: "1", meetingLabel: "Speaker \(slot + 1)")
    }
    private func phrase(_ start: Double, source: LiveAudioSource = .microphone) -> LiveTranscriptPhrase {
        .init(
            session: UUID(), source: source, start: start, end: start + 3,
            text: "One two three",
            words: [
                .init(text: "One", start: start, end: start + 1),
                .init(text: "two", start: start + 1, end: start + 2),
                .init(text: "three", start: start + 2, end: start + 3),
            ])
    }
    private func timeline(
        _ speaker: LiveSpeakerIdentity, start: Double = 0, end: Double = 3,
        through: Double = 10
    ) -> LiveSpeakerTimeline {
        var value = LiveSpeakerTimeline()
        value.speakers = [speaker]
        value.intervals = [.init(source: .microphone, speakerID: speaker.id, start: start, end: end)]
        value.cursors = [
            .init(
                source: .microphone, generation: speaker.generation,
                sequence: 0, end: through, final: false)
        ]
        return value
    }

    @Test func revisionChangesVisibleTailButCannotRewriteSealedPrefix() throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        let first = speaker()
        let second = speaker(1)
        stream.replaceObservationTimeline(timeline(first))
        stream.accept(phrase(0), final: true)
        #expect(stream.frozenCount == 0)
        #expect(stream.hotFinalized.first?.speakerIdentity == first.id)
        stream.replaceObservationTimeline(timeline(second))
        #expect(stream.hotFinalized.first?.speakerIdentity == second.id)
        stream.replaceObservationTimeline(timeline(second, through: 40))
        #expect(stream.frozenCount == 1)
        let sealed = stream.frozenRow(at: 0)
        stream.replaceObservationTimeline(timeline(first, through: 41))
        #expect(stream.frozenRow(at: 0) == sealed)
        #expect(sealed.speakerIdentity == second.id)
    }

    @Test func unknownWordsDoNotBorrowPreviousPersonsName() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        var voice = speaker()
        voice.personID = UUID()
        stream.replaceObservationTimeline(timeline(voice, end: 1))
        stream.accept(phrase(0), final: true)
        let rows = stream.hotFinalized
        #expect(rows.first?.personID == voice.personID)
        #expect(rows.filter { $0.start >= 1 }.allSatisfy { $0.speakerIdentity == nil && $0.personID == nil })
        #expect(rows.flatMap(\.words).map(\.text) == ["One", "two", "three"])
    }

    @Test func reviewedPassageSurvivesIdentityRevisionAndFinishing() throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        let first = speaker()
        let second = speaker(1)
        let original = phrase(0)
        let person = UUID()
        stream.replaceObservationTimeline(timeline(first))
        stream.accept(original, final: true)
        stream.updateEdits(
            [
                .init(
                    anchor: original, text: "Reviewed text", personID: person,
                    personWasAssigned: true)
            ], speakers: [first])
        stream.replaceObservationTimeline(timeline(second))
        #expect(stream.hotFinalized.first?.personID == person)
        #expect(stream.hotFinalized.first?.text == "Reviewed text")
        stream.finish()
        #expect(stream.frozenCount == 1)
        #expect(stream.frozenRow(at: 0).personID == person)
        #expect(stream.frozenRow(at: 0).text == "Reviewed text")
    }

    @Test func sharedVoiceDoesNotLeakActivityAcrossAudioSources() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone, .system])
        var shared = speaker()
        shared.additionalSources = [.system]
        var value = timeline(shared)
        value.cursors.append(
            .init(
                source: .system, generation: shared.generation,
                sequence: 0, end: 10, final: false))
        stream.replaceObservationTimeline(value)
        stream.accept(phrase(0, source: .system), final: true)
        #expect(stream.hotFinalized.allSatisfy { $0.speakerIdentity == nil })
        value.intervals.append(.init(source: .system, speakerID: shared.id, start: 0, end: 3))
        stream.replaceObservationTimeline(value)
        #expect(stream.hotFinalized.first?.speakerIdentity == shared.id)
        stream.finish()
        #expect(stream.frozenCount == 1)
    }
}
