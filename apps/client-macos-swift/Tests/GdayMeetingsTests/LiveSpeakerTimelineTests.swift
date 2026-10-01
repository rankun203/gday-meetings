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

extension LiveSpeakerTimelineTests {
    private func boundaryFixture() -> (LiveSpeakerTimeline, LiveTranscriptPhrase, LiveSpeakerIdentity) {
        let generation = UUID()
        let speaker = identity(.microphone, generation, 1)
        var timeline = LiveSpeakerTimeline()
        _ = timeline.accept(
            .init(
                source: .microphone, generation: generation, sequence: 0,
                speakers: [speaker], intervals: [.init(speakerID: speaker.id, start: 0.2, end: 1.2)], start: 0, end: 1.2
            ))
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 1.2,
            text: "请检查草稿。",
            words: [
                .init(text: "请", start: 0, end: 0.2),
                .init(text: "检查", start: 0.2, end: 0.6), .init(text: "草稿。", start: 0.6, end: 1.2),
            ])
        return (timeline, phrase, speaker)
    }

    @Test func shortUnassignedBoundaryWordStaysWithStableSpeakerAndKeepsPhraseID() {
        let (timeline, phrase, speaker) = boundaryFixture()
        let rows = timeline.attributing(phrase)
        #expect(rows.count == 1)
        #expect(rows[0].text == phrase.text && rows[0].id == phrase.id)
        #expect(rows[0].speakerIdentity == speaker.id)
        #expect(rows[0].speakerLabel == "mic_02")
    }

    @Test func boundaryBridgePreservesKnownShortTurnOverlapAndAudioGaps() {
        let (base, phrase, speaker) = boundaryFixture()
        let other = identity(.microphone, speaker.generation, 0)
        var knownTurn = base
        knownTurn.speakers.append(other)
        knownTurn.intervals.append(.init(speakerID: other.id, start: 0, end: 0.2))
        let knownRows = knownTurn.attributing(phrase)
        #expect(knownRows.map(\.text) == ["请", "检查草稿。"])
        #expect(knownRows[0].speakerIdentity == other.id)
        #expect(knownRows[0].id == phrase.id)
        var overlap = knownTurn
        overlap.intervals.append(.init(speakerID: speaker.id, start: 0, end: 0.2))
        #expect(overlap.attributing(phrase).first?.speakerIdentity == nil)
        #expect(overlap.attributing(phrase).count == 2)
        var missingAudio = base
        missingAudio.gaps = [.init(source: .microphone, start: 0, end: 0.2, reason: "Synthetic gap")]
        #expect(missingAudio.attributing(phrase).count == 2)
        let separateShortPhrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone,
            start: 2, end: 2.2, text: "好", words: [.init(text: "好", start: 2, end: 2.2)])
        #expect(base.attributing(separateShortPhrase).map(\.text) == [separateShortPhrase.text])
        #expect(base.attributing(separateShortPhrase).first?.speakerLabel == "mic_?")
    }

    @Test func zeroDurationWordTimingDoesNotDropCharactersWhenAttributing() {
        let (timeline, original, _) = boundaryFixture()
        var phrase = original
        phrase.words[0].end = phrase.words[0].start
        let rows = timeline.attributing(phrase)
        #expect(rows.count == 1 && rows[0].text == original.text)
        #expect(!phrase.hasCompleteWordTiming)
    }

    @Test func editedBoundaryRangeSurvivesLaterAttributionBridge() {
        let (base, phrase, _) = boundaryFixture()
        var timeline = base
        timeline.gaps = [.init(source: .microphone, start: 0, end: 0.2, reason: "Synthetic gap")]
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "zh")
        draft.speakerTimeline = timeline
        draft.accept(phrase)
        let anchor = draft.resolvedRows().finalized[0]
        draft.updateText("先", for: anchor)
        draft.speakerTimeline?.gaps = []
        let rows = draft.resolvedRows().finalized
        #expect(rows.map(\.text).joined() == "先检查草稿。")
        #expect(rows.first?.id == anchor.id && rows.first?.isUserEdited == true)
        #expect(draft.phrases[0].text == phrase.text)
    }
}

extension LiveSpeakerTimelineTests {
    @Test func interiorBridgeRequiresMatchingNeighborsAndShortUnassignedRun() {
        let generation = UUID()
        let first = identity(.microphone, generation, 0)
        let second = identity(.microphone, generation, 1)
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [first, second]
        timeline.intervals = [
            .init(speakerID: first.id, start: 0, end: 0.8),
            .init(speakerID: first.id, start: 1, end: 1.8),
        ]
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 1.8,
            text: "查看和保存",
            words: [
                .init(text: "查看", start: 0, end: 0.8),
                .init(text: "和", start: 0.8, end: 1), .init(text: "保存", start: 1, end: 1.8),
            ])
        #expect(timeline.attributing(phrase).count == 1)
        timeline.intervals[1].speakerID = second.id
        #expect(timeline.attributing(phrase).map(\.text) == ["查看", "和", "保存"])
        timeline.intervals[1].speakerID = first.id
        timeline.intervals[1].start = 1.7
        var longer = phrase
        longer.words[1].end = 1.7
        longer.words[2].start = 1.7
        #expect(timeline.attributing(longer).map(\.text) == ["查看", "和", "保存"])
    }
}

extension LiveSpeakerTimelineTests {
    @Test func pausedSingletonBridgesOnlyBetweenSameStableSpeaker() {
        let generation = UUID()
        let first = identity(.microphone, generation, 1)
        let second = identity(.microphone, generation, 5)
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [first, second]
        timeline.intervals = [
            .init(speakerID: first.id, start: 0, end: 2),
            .init(speakerID: first.id, start: 2.96, end: 5),
        ]
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 5,
            text: "检查草稿并保存记录。",
            words: [
                .init(text: "检查草稿", start: 0, end: 2),
                .init(text: "并", start: 2, end: 2.96), .init(text: "保存记录。", start: 2.96, end: 5),
            ])
        #expect(timeline.attributing(phrase).map(\.text) == [phrase.text])
        timeline.intervals[1].speakerID = second.id
        #expect(timeline.attributing(phrase).map(\.text) == ["检查草稿", "并", "保存记录。"])
        timeline.intervals[1].speakerID = first.id
        timeline.intervals.append(.init(speakerID: second.id, start: 2.3, end: 2.4))
        #expect(timeline.attributing(phrase).count == 3)
        timeline.intervals.removeLast()
        var longerText = phrase
        longerText.text = "检查草稿然后保存记录。"
        longerText.words[1].text = "然后"
        #expect(timeline.attributing(longerText).count == 3)
        var leading = phrase
        leading.start = 2
        leading.text = "并保存记录。"
        leading.words.removeFirst()
        #expect(timeline.attributing(leading).count == 2)
    }

    @Test func overlappingOrReorderedWordTimesKeepOriginalText() {
        let (timeline, original, _) = boundaryFixture()
        var overlapping = original
        overlapping.words[1].start = 0.1
        #expect(!overlapping.hasCompleteWordTiming)
        #expect(timeline.attributing(overlapping).map(\.text) == [original.text])
        var reversed = original
        reversed.words.swapAt(0, 1)
        #expect(!reversed.hasCompleteWordTiming)
        #expect(timeline.attributing(reversed).map(\.text) == [original.text])
    }
}

extension LiveSpeakerTimelineTests {
    @Test func leadingWordRequiresCorroboratedPreviousPhraseAndKeepsRawBoundaries() {
        let session = UUID()
        let generation = UUID()
        let speaker = identity(.system, generation, 1)
        let other = identity(.system, generation, 0)
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [speaker, other]
        timeline.intervals = [
            .init(speakerID: speaker.id, start: 0, end: 2),
            .init(speakerID: speaker.id, start: 3.2, end: 5),
        ]
        let previous = LiveTranscriptPhrase(
            session: session, source: .system, start: 0, end: 2,
            text: "Review the draft.", words: [.init(text: "Review the draft.", start: 0, end: 2)])
        let current = LiveTranscriptPhrase(
            session: session, source: .system, start: 2, end: 5,
            text: "Then save the changes.",
            words: [
                .init(text: "Then", start: 2, end: 3.2),
                .init(text: "save the changes.", start: 3.2, end: 5),
            ])
        #expect(timeline.attributing(current).count == 2)
        #expect(timeline.attributing(current).first?.speakerLabel == "sys_?")
        let joined = timeline.attributing(current, preceding: previous)
        #expect(joined.count == 1 && joined[0].text == current.text && joined[0].id == current.id)
        #expect(joined[0].speakerIdentity == speaker.id)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.speakerTimeline = timeline
        draft.accept(previous)
        draft.accept(current)
        #expect(draft.resolvedRows().finalized.map(\.text) == [previous.text, current.text])
        #expect(draft.phrases.count == 2)
        var anotherSession = previous
        anotherSession.session = UUID()
        #expect(timeline.attributing(current, preceding: anotherSession).count == 2)
        timeline.gaps = [.init(source: .system, start: 2, end: 2.1, reason: "Synthetic gap")]
        #expect(timeline.attributing(current, preceding: previous).count == 2)
        timeline.gaps = []
        timeline.intervals.append(.init(speakerID: other.id, start: 2.3, end: 2.5))
        #expect(timeline.attributing(current, preceding: previous).count == 2)
        timeline.intervals.removeLast()
        timeline.intervals[0].speakerID = other.id
        #expect(timeline.attributing(current, preceding: previous).count == 2)
    }

    @Test func unknownDiarizationIsDistinctFromFirstSlotAndPreAnalysisDefault() {
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 1,
            text: "Example", words: [.init(text: "Example", start: 0, end: 1)])
        var timeline = LiveSpeakerTimeline()
        #expect(timeline.attributing(phrase).first?.speakerLabel == "mic_01")
        let speaker = identity(.microphone, UUID(), 0)
        timeline.speakers = [speaker]
        #expect(timeline.attributing(phrase).first?.speakerLabel == "mic_?")
        #expect(timeline.attributing(phrase).first?.speakerIdentity == nil)
        timeline.intervals = [.init(speakerID: speaker.id, start: 0, end: 1)]
        #expect(timeline.attributing(phrase).first?.speakerLabel == "mic_01")
        #expect(timeline.attributing(phrase).first?.speakerIdentity == speaker.id)
    }
}
