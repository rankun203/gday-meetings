import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptStreamTests {
    private let session = UUID()
    private let generation = UUID()

    private func speaker(_ slot: Int = 0, source: LiveAudioSource = .system) -> LiveSpeakerIdentity {
        .init(id: UUID(), source: source, generation: generation, slot: slot, model: "synthetic", revision: "1")
    }
    private func phrase(_ start: Double, _ words: [String], source: LiveAudioSource = .system) -> LiveTranscriptPhrase {
        .init(
            session: session, source: source, start: start, end: start + Double(words.count),
            text: words.joined(separator: " "),
            words: words.enumerated().map {
                .init(text: $0.element, start: start + Double($0.offset), end: start + Double($0.offset + 1))
            })
    }
    private func event(
        _ speakers: [LiveSpeakerIdentity], _ intervals: [LiveSpeakerInterval], start: Double = 0,
        end: Double, sequence: Int = 0
    ) -> LiveSpeakerEvent {
        .init(
            source: speakers[0].source, generation: generation, sequence: sequence,
            speakers: speakers, intervals: intervals, start: start, end: end)
    }

    @Test func carriesUnknownWordsUsingTheMostRecentSpeaker() throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 3))
        stream.accept(phrase(0, ["One", "two", "three"]), final: true)
        #expect(stream.snapshot.phrases.map(\.speakerIdentity).allSatisfy { $0 == voice.id })
        #expect(stream.snapshot.phrases.flatMap(\.words).map(\.text) == ["One", "two", "three"])
    }

    @Test func catchUpSplitsHotWordsAndLeavesFrozenPrefixUntouched() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let first = speaker()
        let second = speaker(1)
        stream.accept(event([first, second], [.init(speakerID: first.id, start: 0, end: 1)], end: 1))
        stream.accept(phrase(0, ["First"]), final: true)
        let frozen = stream.frozenRow(at: 0)
        stream.accept(phrase(1, ["Next", "voice"]), final: true)
        #expect(stream.hotFinalized.first?.speakerIdentity == first.id)
        stream.accept(
            event(
                [first, second], [.init(speakerID: second.id, start: 1, end: 3)],
                start: 1, end: 3, sequence: 1))
        #expect(stream.frozenRow(at: 0) == frozen)
        #expect(stream.snapshot.phrases.last?.speakerIdentity == second.id)
    }

    @Test func carryIsSourceScopedAndStopsAtGapOrSessionChange() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 6))
        stream.accept(phrase(0, ["First"]), final: true)
        stream.accept(phrase(1, ["Microphone"], source: .microphone), final: true)
        #expect(stream.hotFinalized.first?.speakerIdentity == nil)
        stream.accept(.init(source: .system, start: 1, end: 2, reason: "Synthetic gap"))
        stream.accept(phrase(2, ["After"]), final: true)
        var restarted = phrase(4, ["Restart"])
        restarted.session = UUID()
        stream.accept(restarted, final: true)
        stream.finish()
        #expect(stream.snapshot.phrases.filter { $0.start >= 1 }.allSatisfy { $0.speakerIdentity == nil })
        #expect(stream.snapshot.phrases.allSatisfy { !$0.speakerLabel.contains("?") })
    }

    @Test func delayedRecognitionStillUsesEarlierEmittedActivity() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 8)], end: 10))
        stream.accept(phrase(1, ["Delayed", "recognition"]), final: true)
        #expect(stream.snapshot.phrases.first?.speakerIdentity == voice.id)
    }

    @Test func stalledLabelsKeepAttributionWorkBoundedAcrossTwoHours() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        for second in 0..<7200 {
            stream.accept(phrase(Double(second), ["word"]), final: true)
            #expect(stream.attributedPhraseCount <= 31)
            #expect(stream.hotFinalized.count <= 30)
        }
        #expect(stream.frozenCount == 7170)
        let old = stream.frozenRow(at: 0)
        stream.accept(phrase(7200, ["last"]), final: false)
        #expect(stream.frozenRow(at: 0) == old)
        #expect(stream.attributedPhraseCount <= 31)
    }

    @Test func growingTimedPartialCommitsOldPrefixWithoutLosingWords() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        for count in 1...120 {
            var value = phrase(0, (0..<count).map { "word\($0)" })
            value.recognizedFinal = false
            stream.accept(value, final: false)
            #expect(stream.hotPartials.flatMap(\.words).count <= 30)
        }
        stream.accept(phrase(0, (0..<120).map { "word\($0)" }), final: true)
        stream.finish()
        #expect(stream.snapshot.phrases.flatMap(\.words).map(\.text) == (0..<120).map { "word\($0)" })
        #expect(stream.snapshot.phrases.allSatisfy { $0.recognitionIsFinal })
    }

    @Test func untimedLongPartialPreservesText() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let text = String(repeating: "Synthetic text. ", count: 1000)
        let phrase = LiveTranscriptPhrase(session: session, source: .system, start: 0, end: 120, text: text)
        stream.accept(phrase, final: false)
        #expect(stream.hotPartials.first?.text == text)
        stream.accept(phrase, final: true)
        stream.finish()
        #expect(stream.snapshot.phrases.first?.text == text)
    }

    @Test func savedEffectiveLabelsSurviveReopenAndEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = speaker()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 3))
        stream.accept(phrase(0, ["One", "two", "three"]), final: true)
        stream.finish()
        var draft = LiveTranscriptDraft(meetingID: session, locale: "en")
        draft.effectivePhrases = stream.snapshot.phrases
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: [voice])
        try draft.save(at: directory)
        var read = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: session))
        #expect(read.segments.allSatisfy { $0.speaker == voice.label })
        read.updateText("Edited text", for: try #require(read.resolvedRows().finalized.first))
        try read.save(at: directory)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: session)?.segments.first?.text == "Edited text")
    }

    @Test func selectedSourcesWaitForOrderingAndLateDeliveryRetainsText() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false, sources: [.microphone, .system])
        stream.accept(phrase(10, ["System"]), final: true)
        #expect(stream.frozenCount == 0)
        stream.accept(phrase(5, ["Microphone"], source: .microphone), final: true)
        stream.accept(phrase(50, ["Later"]), final: true)
        stream.accept(phrase(2, ["Late microphone"], source: .microphone), final: true)
        stream.finish()
        // Already sealed recognition is immutable. A provider cannot replace it.
        #expect(stream.snapshot.phrases.map(\.start) == [5, 10, 50])
    }

    @Test func gapRemainsABarrierAfterActivityPruning() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 1))
        stream.accept(phrase(0, ["Before"]), final: true)
        stream.accept(.init(source: .system, start: 2, end: 3, reason: "Synthetic gap"))
        stream.accept(event([voice], [], start: 1, end: 100, sequence: 1))
        stream.accept(phrase(99, ["After"]), final: true)
        #expect(stream.snapshot.phrases.last?.speakerIdentity == nil)
    }

    @Test func overrideSpanningFrozenAndHotAppearsOnceAfterMoreFinals() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 1))
        stream.accept(phrase(0, ["First"]), final: true)
        stream.accept(phrase(1, ["Second"]), final: true)
        let anchor = phrase(0, ["First", "Second"])
        let edit = LiveTranscriptOverride(anchor: anchor, text: "Corrected passage")
        stream.updateEdits([edit], speakers: [voice])
        #expect((0..<stream.frozenCount).map { stream.frozenRow(at: $0).text } == ["Corrected passage"])
        #expect(stream.hotFinalized.isEmpty)
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 1, end: 3)], start: 1, end: 3, sequence: 1))
        stream.accept(phrase(2, ["Third"]), final: true)
        let displayed = (0..<stream.frozenCount).map { stream.frozenRow(at: $0) } + stream.hotFinalized
        #expect(displayed.filter { $0.id == anchor.id }.count == 1)
        #expect(displayed.map(\.text) == ["Corrected passage", "Third"])
    }

    @Test func invalidInputCannotPoisonProjection() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        var invalid = phrase(0, ["invalid"])
        invalid.end = .nan
        stream.accept(invalid, final: true)
        stream.accept(phrase(1, ["valid"]), final: true)
        #expect(stream.snapshot.phrases.map(\.text) == ["valid"])
    }

    @Test @MainActor func controllerSavesOnlyCanonicalSegmentsAndEditsRemainAuthoritative() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: session, language: "en", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        controller.finalizeDetachedSession(
            token: token,
            work: {
                controller.receive(phrase(0, ["Original"]), final: true, token: token)
                return true
            }, cancel: nil)
        await controller.finish()
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("live-transcript.json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(LiveTranscriptProjection.checkpointName).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("live-transcript-events.csv").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("live-transcript-events.saved.csv").path))
        var saved = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: session))
        saved.updateText("Saved correction", for: try #require(saved.resolvedRows().finalized.first))
        try saved.save(at: directory)
        #expect(
            try LiveTranscriptDraft.read(at: directory, meetingID: session)?.segments.first?.text == "Saved correction")
    }

    @Test func lateOtherSourceAppendsWithoutRebuildingFrozenHistory() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false, sources: [.microphone, .system])
        stream.accept(phrase(10, ["System"]), final: true)
        stream.accept(phrase(50, ["Later"]), final: true)
        let frozen = stream.frozenRow(at: 0)
        let reset = stream.resetRevision
        stream.accept(phrase(5, ["Late microphone"], source: .microphone), final: true)
        #expect(stream.frozenRow(at: 0) == frozen)
        #expect(stream.resetRevision == reset)
        #expect(stream.snapshot.phrases.map(\.start) == [10, 5, 50])
    }

    @Test func overrideSpanningFinalAndPartialHotRowsAppearsOnce() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        stream.accept(phrase(0, ["First"]), final: true)
        var partial = phrase(1, ["Second"])
        partial.recognizedFinal = false
        stream.accept(partial, final: false)
        let anchor = phrase(0, ["First", "Second"])
        stream.updateEdits([.init(anchor: anchor, text: "One correction")], speakers: [])
        #expect((stream.hotFinalized + stream.hotPartials).filter { $0.id == anchor.id }.count == 1)
    }

    @Test @MainActor func unrelatedRawEventsCannotOverrideFrozenTextAndLatestEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: session, language: "en", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        controller.finalizeDetachedSession(
            token: token,
            work: {
                controller.receive(phrase(0, ["First"]), final: true, token: token)
                controller.receive(phrase(60, ["Last"]), final: true, token: token)
                controller.updateText(phrase: controller.presentedStream.frozenRow(at: 0), text: "Corrected first")
                await controller.flushCheckpoint()
                do {
                    try Data("unrelated raw events".utf8).write(
                        to: directory.appendingPathComponent("live-transcript-events.csv"))
                }
                catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
                return true
            }, cancel: nil)
        await controller.finish()
        let saved = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: session))
        #expect(saved.segments.map(\.text) == ["Corrected first", "Last"])
        #expect(saved.complete == false)
    }

    @Test func modelRestartDoesNotInheritTheOldVoice() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let original = speaker()
        stream.accept(event([original], [.init(speakerID: original.id, start: 0, end: 1)], end: 1))
        stream.accept(phrase(0, ["First"]), final: true)
        var restarted = speaker()
        restarted.generation = UUID()
        stream.accept(
            .init(
                source: .system, generation: restarted.generation, sequence: 0,
                speakers: [restarted], intervals: [], start: 1, end: 3))
        stream.accept(phrase(2, ["Restart"]), final: true)
        #expect(stream.snapshot.phrases.last?.speakerIdentity == nil)
    }

    @Test func savedAutomaticAssociationUsesCurrentSpeakerMetadata() throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        var voice = speaker()
        stream.accept(event([voice], [.init(speakerID: voice.id, start: 0, end: 1)], end: 1))
        stream.accept(phrase(0, ["Example"]), final: true)
        let person = UUID()
        voice.personID = person
        stream.updateEdits([], speakers: [voice])
        var draft = LiveTranscriptDraft(meetingID: session, locale: "en")
        draft.effectivePhrases = stream.snapshot.phrases
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: [voice])
        #expect(draft.resolvedRows().finalized.first?.personID == person)
        #expect(draft.speakers.first?.personID == person)
        #expect(stream.snapshot.phrases.first?.personID == nil)
    }

    @Test func volatileCutoffPreservesWholeWordTiming() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        var value = phrase(0.25, (0..<40).map { "word\($0)" })
        value.words[value.words.count - 1].end += 0.3
        value.end += 0.3
        value.recognizedFinal = false
        stream.accept(value, final: false)
        #expect(stream.snapshot.phrases.allSatisfy { $0.hasCompleteWordTiming })
        #expect(stream.hotPartials.allSatisfy { $0.hasCompleteWordTiming })
        #expect(stream.snapshot.phrases.flatMap(\.words).count + stream.hotPartials.flatMap(\.words).count == 40)
    }

    @Test func detachedRecognitionSessionCanDeliverAfterNewerSessionFreezes() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        var newer = phrase(50, ["New session"])
        newer.session = UUID()
        stream.accept(newer, final: true)
        let frozen = stream.frozenRow(at: 0)
        stream.accept(phrase(0, ["Detached final"]), final: true)
        #expect(stream.frozenRow(at: 0) == frozen)
        #expect(stream.snapshot.phrases.map(\.text) == ["New session", "Detached final"])
    }

}
