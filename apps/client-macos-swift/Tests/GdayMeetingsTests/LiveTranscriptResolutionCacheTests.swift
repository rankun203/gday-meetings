import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptResolutionCacheTests {
    static func fixture(minutes: Int) -> LiveTranscriptDraft {
        let generation = UUID()
        let session = UUID()
        let identities = (0..<4).map { slot in
            LiveSpeakerIdentity(
                id: UUID(), source: slot < 2 ? .microphone : .system,
                generation: generation, slot: slot % 2, model: "synthetic", revision: "test")
        }
        var timeline = LiveSpeakerTimeline(speakers: identities)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        for position in 0..<(minutes * 30) {
            let start = Double(position * 2)
            let source: LiveAudioSource = position.isMultiple(of: 2) ? .microphone : .system
            let speaker = identities[(source == .microphone ? 0 : 2) + position / 2 % 2]
            for part in 0..<4 {
                let lower = start + Double(part) * 0.45
                timeline.intervals.append(.init(speakerID: speaker.id, start: lower, end: lower + 0.4))
            }
            draft.phrases.append(
                .init(
                    session: session, source: source, start: start, end: start + 1.8,
                    text: "A sample sentence.",
                    words: [
                        .init(text: "A", start: start, end: start + 0.4),
                        .init(text: "sample", start: start + 0.45, end: start + 0.85),
                        .init(text: "sentence.", start: start + 0.9, end: start + 1.8),
                    ]))
        }
        timeline.cursors = [LiveAudioSource.microphone, .system].map {
            .init(source: $0, generation: generation, sequence: 1, end: Double(minutes * 60), final: false)
        }
        draft.speakerTimeline = timeline
        return draft
    }

    static func reference(_ draft: LiveTranscriptDraft, partials: [LiveTranscriptPhrase] = []) -> (
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]
    ) {
        var preceding: [LiveAudioSource: LiveTranscriptPhrase] = [:]
        func attribute(_ phrases: [LiveTranscriptPhrase], final: Bool) -> [LiveTranscriptPhrase] {
            phrases.sorted(by: LiveTranscriptPhrase.ordered).flatMap { phrase in
                let rows = draft.speakerTimeline?.attributing(phrase, preceding: preceding[phrase.source]) ?? [phrase]
                preceding[phrase.source] = phrase
                return rows.map {
                    var row = $0
                    row.recognizedFinal = final
                    return row
                }
            }
        }
        return (attribute(draft.phrases, final: true), attribute(partials, final: false))
    }

    @Test func indexedAttributionMatchesFullTimelineWithLongOverlapAndGaps() {
        var draft = Self.fixture(minutes: 2)
        let identity = draft.speakerTimeline!.speakers[0]
        draft.speakerTimeline!.intervals.append(.init(speakerID: identity.id, start: 0, end: 120))
        draft.speakerTimeline!.gaps = [.init(source: .microphone, start: 6, end: 7, reason: "Synthetic gap")]
        let expected = Self.reference(draft)
        let actual = draft.resolvedRows()
        #expect(actual.finalized == expected.finalized)
        #expect(actual.partials == expected.partials)
    }

    @Test func stableHistoryIsCachedWhileTailAndIdentityChangesRemainVisible() {
        var draft = Self.fixture(minutes: 2)
        let cache = LiveTranscriptResolutionCache()
        _ = draft.resolvedRows(cache: cache)
        #expect(cache.attributionCount == draft.phrases.count)
        _ = draft.resolvedRows(cache: cache)
        #expect(cache.attributionCount == 0)
        draft.speakerTimeline!.cursors[0].end += 1
        draft.speakerTimeline!.cursors[0].sequence += 1
        draft.phrases[draft.phrases.count - 1].text = "Changed sample."
        draft.phrases[draft.phrases.count - 1].words = []
        let changed = draft.resolvedRows(cache: cache)
        #expect(cache.attributionCount == 1)
        #expect(changed.finalized == Self.reference(draft).finalized)
        draft.speakerTimeline!.speakers[0].personID = UUID()
        #expect(draft.resolvedRows(cache: cache).finalized == Self.reference(draft).finalized)
        draft.speakerTimeline!.intervals.removeFirst()
        #expect(draft.resolvedRows(cache: cache).finalized == Self.reference(draft).finalized)
    }

    @Test func overridesAndMeetingChangesCannotReuseStaleRows() {
        var draft = Self.fixture(minutes: 1)
        let cache = LiveTranscriptResolutionCache()
        let phrase = draft.resolvedRows(cache: cache).finalized[0]
        draft.updateText("Edited sentence.", for: phrase)
        draft.assignPerson(UUID(), for: phrase)
        #expect(draft.resolvedRows(cache: cache).finalized == draft.resolvedRows().finalized)
        let other = Self.fixture(minutes: 1)
        #expect(other.resolvedRows(cache: cache).finalized == Self.reference(other).finalized)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
    func benchmarkFiveFortyFiveAndOneHundredTwentyMinutes() {
        for minutes in [5, 45, 120] {
            var draft = Self.fixture(minutes: minutes)
            let cache = LiveTranscriptResolutionCache()
            _ = draft.resolvedRows(cache: cache)
            var baselineSeconds = 0.0
            var indexedSeconds = 0.0
            let last = draft.phrases.last!
            var partial = LiveTranscriptPhrase(
                session: last.session, source: last.source,
                start: Double(minutes * 60), end: Double(minutes * 60), text: "Sample update.")
            let speaker = draft.speakerTimeline!.speakers.first { $0.source == partial.source }!
            for update in 0..<3 {
                let previousEnd = partial.end
                partial.end += 0.3
                partial.text = "Sample update \(update)."
                draft.speakerTimeline!.intervals.append(
                    .init(speakerID: speaker.id, start: previousEnd, end: partial.end))
                for index in draft.speakerTimeline!.cursors.indices {
                    if draft.speakerTimeline!.cursors[index].source == partial.source {
                        draft.speakerTimeline!.cursors[index].end = partial.end
                        draft.speakerTimeline!.cursors[index].sequence += 1
                    }
                }
                var start = ProcessInfo.processInfo.systemUptime
                let baseline = Self.reference(draft, partials: [partial])
                baselineSeconds += ProcessInfo.processInfo.systemUptime - start
                start = ProcessInfo.processInfo.systemUptime
                let indexed = draft.resolvedRows(partials: [partial], cache: cache)
                indexedSeconds += ProcessInfo.processInfo.systemUptime - start
                #expect(indexed.finalized == baseline.finalized)
                #expect(indexed.partials == baseline.partials)
                #expect(cache.attributionCount == 1)
                #expect(cache.finalizedAssemblyCount == 0)
            }
            print(
                "LIVE-ATTRIBUTION minutes=\(minutes) updates=3 baseline_ms=\(baselineSeconds * 1000) indexed_ms=\(indexedSeconds * 1000)"
            )
        }
    }
}
