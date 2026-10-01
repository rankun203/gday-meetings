import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct LiveSpeakerTimelineTests {
    private func identity(_ source: LiveAudioSource, _ generation: UUID, _ slot: Int) -> LiveSpeakerIdentity {
        .init(
            id: UUID(), source: source, generation: generation, slot: slot, model: "synthetic-model", revision: "test")
    }
    @Test func sourceGenerationsRejectStaleEventsAndDoNotReuseIdentities() {
        var timeline = LiveSpeakerTimeline()
        let generation = UUID()
        let nextGeneration = UUID()
        let first = identity(.system, generation, 0)
        let accepted1 = timeline.accept(
            .init(
                source: .system, generation: generation, sequence: 0,
                speakers: [first], intervals: [], start: 0, end: 0))
        #expect(accepted1)
        let accepted2 = timeline.accept(
            .init(
                source: .system, generation: generation, sequence: 1,
                speakers: [first], intervals: [.init(speakerID: first.id, start: 0, end: 1)], start: 0, end: 1))
        #expect(accepted2)
        let next = identity(.system, nextGeneration, 0)
        let accepted3 = timeline.accept(
            .init(
                source: .system, generation: nextGeneration, sequence: 0,
                speakers: [next], intervals: [], start: 2, end: 2))
        #expect(accepted3)
        let accepted4 = !timeline.accept(
            .init(
                source: .system, generation: generation, sequence: 2,
                speakers: [first], intervals: [], start: 1, end: 2))
        #expect(accepted4)
        #expect(first.label == next.label && first.id != next.id)
        #expect(timeline.speakers.count == 2)
    }

    @Test func timedWordsSplitByIdentityAndKeepOverlapUnassigned() {
        var timeline = LiveSpeakerTimeline()
        let generation = UUID()
        let first = identity(.system, generation, 0)
        let second = identity(.system, generation, 1)
        let accepted5 = timeline.accept(
            .init(
                source: .system, generation: generation, sequence: 0,
                speakers: [first, second],
                intervals: [
                    .init(speakerID: first.id, start: 0, end: 2),
                    .init(speakerID: second.id, start: 1, end: 3),
                ], start: 0, end: 3))
        #expect(accepted5)
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 3,
            text: "First overlap last",
            words: [
                .init(text: "First", start: 0, end: 1),
                .init(text: "overlap", start: 1, end: 2),
                .init(text: "last", start: 2, end: 3),
            ])
        let rows = timeline.attributing(phrase)
        #expect(rows.map(\.text) == ["First", "overlap", "last"])
        #expect(rows.map(\.speakerIdentity) == [first.id, nil, second.id])
        #expect(timeline.attributing(phrase).map(\.id) == rows.map(\.id))
        var noWords = phrase
        noWords.words = []
        #expect(timeline.attributing(noWords).count == 1)
        #expect(timeline.attributing(noWords).first?.speakerIdentity == nil)
    }

    @Test func manualNamesWinAndDoNotLeakAcrossSources() {
        var timeline = LiveSpeakerTimeline()
        let generation = UUID()
        let person = UUID()
        let microphone = identity(.microphone, generation, 0)
        let system = identity(.system, generation, 0)
        for speaker in [microphone, system] {
            let accepted6 = timeline.accept(
                .init(
                    source: speaker.source, generation: generation, sequence: 0,
                    speakers: [speaker], intervals: [.init(speakerID: speaker.id, start: 0, end: 1)], start: 0,
                    end: 1))
            #expect(accepted6)
        }
        timeline.assign(person, to: microphone.id, manual: true)
        timeline.assign(UUID(), to: microphone.id, manual: false)
        #expect(timeline.speakers.first(where: { $0.id == microphone.id })?.personID == person)
        #expect(timeline.speakers.first(where: { $0.id == system.id })?.personID == nil)
        timeline.assign(nil, to: microphone.id, manual: true)
        timeline.assign(UUID(), to: microphone.id, manual: false)
        #expect(timeline.speakers.first(where: { $0.id == microphone.id })?.personID == nil)
    }

    @Test func textAndLineOverridesSurviveLaterDiarization() {
        let generation = UUID()
        let person = UUID()
        let speaker = identity(.system, generation, 0)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let phrase = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 1, text: "Recognized")
        draft.accept(phrase)
        draft.updateText("Edited", for: phrase)
        draft.assignPerson(person, for: phrase)
        draft.speakerTimeline = LiveSpeakerTimeline()
        #expect(
            draft.speakerTimeline?.accept(
                .init(
                    source: .system, generation: generation, sequence: 0,
                    speakers: [speaker], intervals: [.init(speakerID: speaker.id, start: 0, end: 1)], start: 0, end: 1))
                == true)
        #expect(draft.segments.first?.text == "Edited")
        #expect(draft.speakers.first?.personID == person)
        #expect(draft.segments.first?.speakerID == phrase.id)
    }

    @Test func independentAudioSubscribersReceiveWholePacketsAndIsolateOverflow() async throws {
        let sink = LiveAudioSink()
        let fast = LiveAudioQueue()
        let slow = LiveAudioQueue()
        let speakerConsumer = UUID()
        sink.replace([.system: fast])
        sink.replace([.system: slow], consumer: speakerConsumer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        var fastIterator = fast.stream.makeAsyncIterator()
        for index in 0..<3 {
            sink.append(buffer, start: Double(index), source: .system)
            let packet = try #require(await fastIterator.next())
            #expect(packet.start == Double(index))
            fast.consumed(packet)
        }
        #expect(fast.takeDroppedRanges().isEmpty)
        #expect(slow.takeDroppedRanges().count == 1)
        sink.replace([:])
        var slowIterator = slow.stream.makeAsyncIterator()
        let first = try #require(await slowIterator.next())
        slow.consumed(first)
        sink.append(buffer, start: 3, source: .system)
        let second = try #require(await slowIterator.next())
        slow.consumed(second)
        let third = try #require(await slowIterator.next())
        #expect(third.start == 3)
        sink.replace([:], consumer: speakerConsumer)
        fast.finish()
        slow.finish()
    }
}

extension LiveSpeakerTimelineTests {
    @Test func retiredGenerationCannotRestartAtSequenceZero() throws {
        var timeline = LiveSpeakerTimeline()
        let old = UUID()
        let next = UUID()
        let accepted7 = timeline.accept(
            .init(source: .system, generation: old, sequence: 0, speakers: [], intervals: [], start: 0, end: 1))
        #expect(accepted7)
        let accepted8 = timeline.accept(
            .init(source: .system, generation: next, sequence: 0, speakers: [], intervals: [], start: 1, end: 2))
        #expect(accepted8)
        timeline = try JSONDecoder().decode(LiveSpeakerTimeline.self, from: JSONEncoder().encode(timeline))
        let accepted9 = !timeline.accept(
            .init(source: .system, generation: old, sequence: 0, speakers: [], intervals: [], start: 2, end: 3))
        #expect(accepted9)
        let accepted10 = !timeline.accept(
            .init(source: .system, generation: UUID(), sequence: 0, speakers: [], intervals: [], start: 0, end: 1))
        #expect(accepted10)
    }

    @Test func activityHysteresisSuppressesShortBurstsAndRetainsOverlap() {
        var filter = LiveSpeakerActivityFilter()
        var values = Array(repeating: Float(0), count: 8)
        values[0] = 0.8
        for _ in 0..<4 {
            let accepted11 = !filter.accept(values)[0]
            #expect(accepted11)
        }
        let accepted12 = filter.accept(values)[0]
        #expect(accepted12)
        values[0] = 0.5
        values[1] = 0.8
        for _ in 0..<5 {
            let accepted13 = filter.accept(values)[0]
            #expect(accepted13)
        }
        let accepted14 = filter.accept(values)[1]
        #expect(accepted14)
        values[0] = 0.1
        for _ in 0..<9 {
            let accepted15 = filter.accept(values)[0]
            #expect(accepted15)
        }
        let accepted16 = !filter.accept(values)[0]
        #expect(accepted16)
        let accepted17 = filter.accept(values)[1]
        #expect(accepted17)
    }

    @Test func cleanEmbeddingSurvivesCheckpointWithoutEnrollingPerson() throws {
        var timeline = LiveSpeakerTimeline()
        let generation = UUID()
        let speaker = identity(.microphone, generation, 0)
        let accepted18 = timeline.accept(
            .init(
                source: .microphone, generation: generation, sequence: 0,
                speakers: [speaker], intervals: [.init(speakerID: speaker.id, start: 0, end: 2)], start: 0, end: 2))
        #expect(accepted18)
        let embedding = try #require(
            TypedVoiceEmbedding.normalizing(type: .community1, values: Array(repeating: 1, count: 256)))
        timeline.retainEmbedding(embedding, for: speaker.id)
        timeline = try JSONDecoder().decode(LiveSpeakerTimeline.self, from: JSONEncoder().encode(timeline))
        let row = timeline.attributing(
            .init(session: UUID(), source: .microphone, start: 0, end: 2, text: "Synthetic phrase", words: []))[0]
        #expect(row.voiceEmbedding == embedding)
        #expect(row.personID == nil)
        #expect(!timeline.speakers[0].manuallyAssigned)
    }
}

extension LiveSpeakerTimelineTests {
    @Test func scopedOverridesFollowReassignmentWhileLineCorrectionsStayIndependent() throws {
        let generation = UUID()
        let session = UUID()
        let firstPerson = UUID()
        let secondPerson = UUID()
        let speaker = identity(.system, generation, 0)
        var timeline = LiveSpeakerTimeline()
        let accepted19 = timeline.accept(
            .init(
                source: .system, generation: generation, sequence: 0, speakers: [speaker],
                intervals: [.init(speakerID: speaker.id, start: 0, end: 4)], start: 0, end: 4))
        #expect(accepted19)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.speakerTimeline = timeline
        draft.accept(.init(session: session, source: .system, start: 0, end: 2, text: "First phrase", words: []))
        draft.accept(.init(session: session, source: .system, start: 2, end: 4, text: "Second phrase", words: []))
        let rows = draft.resolvedRows().finalized
        draft.assignPerson(firstPerson, for: rows[0], speakerIdentity: speaker.id)
        draft.speakerTimeline?.assign(firstPerson, to: speaker.id, manual: true)
        draft.assignPerson(firstPerson, for: rows[1])
        draft.speakerTimeline?.assign(secondPerson, to: speaker.id, manual: true)
        let changed = draft.resolvedRows().finalized
        #expect(changed[0].personID == secondPerson)
        #expect(changed[0].speakerIdentity == speaker.id)
        #expect(changed[1].personID == firstPerson)
        #expect(changed[1].speakerIdentity == nil)
        draft.speakerTimeline?.assign(nil, to: speaker.id, manual: true)
        #expect(draft.resolvedRows().finalized[0].personID == nil)
    }
}

extension LiveSpeakerTimelineTests {
    @Test func recognitionOnlyPresentationHidesAnonymousModelIdentityButKeepsNamedRows() {
        var row = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 1,
            text: "Synthetic phrase", words: [])
        row.speakerIdentity = UUID()
        row.diarizationLabel = "sys_04"
        let hidden = row.displayingSpeakerLabels(false)
        #expect(hidden.speakerLabel == "sys_01")
        #expect(hidden.speakerIdentity == nil)
        #expect(row.speakerIdentity != nil && row.diarizationLabel == "sys_04")
        #expect(row.displayingSpeakerLabels(true) == row)
        row.personID = UUID()
        #expect(row.displayingSpeakerLabels(false) == row)
    }
}

extension LiveSpeakerTimelineTests {
    @Test func removedPersonUsesAnonymousDisplayPolicyWithoutChangingDraftIdentity() {
        var row = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 0, end: 1,
            text: "Synthetic phrase", words: [])
        let person = UUID()
        let speaker = UUID()
        row.personID = person
        row.speakerIdentity = speaker
        row.diarizationLabel = "sys_04"
        let removed = row.displayingSpeakerLabels(false, knownPeople: [])
        #expect(removed.personID == nil && removed.speakerIdentity == nil)
        #expect(removed.speakerLabel == "sys_01")
        #expect(row.personID == person && row.speakerIdentity == speaker)
        #expect(row.displayingSpeakerLabels(false, knownPeople: [person]) == row)
        let shown = row.displayingSpeakerLabels(true, knownPeople: [])
        #expect(shown.personID == nil && shown.speakerLabel == "sys_04")
    }
}
