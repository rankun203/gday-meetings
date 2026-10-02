import Foundation
import Testing

@testable import GdayMeetings

struct LiveSpeakerGapIndexTests {
    static func fixture(minutes: Int) -> LiveTranscriptDraft {
        var draft = LiveTranscriptResolutionCacheTests.fixture(minutes: minutes)
        // One long range must not force every query to scan all shorter ranges.
        draft.speakerTimeline!.gaps = [
            .init(source: .microphone, start: 0, end: Double(minutes * 60), reason: "Coverage is uncertain.")
        ]
        for index in 0..<(minutes * 120) {
            let start = Double(index) * 0.5
            draft.speakerTimeline!.gaps.append(
                .init(
                    source: index.isMultiple(of: 2) ? .system : .microphone,
                    start: start, end: start + 0.02, reason: "Synthetic interruption."))
        }
        let identity = draft.speakerTimeline!.speakers[0]
        draft.speakerTimeline!.intervals.append(
            .init(speakerID: identity.id, start: 0, end: Double(minutes * 60)))
        return draft
    }

    @Test func stormAndLateGapCorrectionsMatchFullHistoryAttribution() {
        var draft = Self.fixture(minutes: 5)
        let cache = LiveTranscriptResolutionCache()
        #expect(
            draft.resolvedRows(cache: cache).finalized == LiveTranscriptResolutionCacheTests.reference(draft).finalized)
        _ = draft.resolvedRows(cache: cache)
        #expect(cache.attributionCount == 0)
        // Gap-only changes must refresh the gap index without changing speaker activity.
        draft.speakerTimeline!.gaps.append(.init(source: .system, start: 18, end: 19, reason: "Late interruption."))
        #expect(
            draft.resolvedRows(cache: cache).finalized == LiveTranscriptResolutionCacheTests.reference(draft).finalized)
        draft.speakerTimeline!.gaps.removeAll { $0.source == .microphone }
        #expect(
            draft.resolvedRows(cache: cache).finalized == LiveTranscriptResolutionCacheTests.reference(draft).finalized)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
    func benchmarkLongHistoriesWithGapStorm() {
        for minutes in [45, 120] {
            let draft = Self.fixture(minutes: minutes)
            let cache = LiveTranscriptResolutionCache()
            _ = draft.resolvedRows(cache: cache)
            let baselineStart = ProcessInfo.processInfo.systemUptime
            let baseline = LiveTranscriptResolutionCacheTests.reference(draft)
            let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart
            let indexedStart = ProcessInfo.processInfo.systemUptime
            let indexed = draft.resolvedRows(cache: cache)
            let indexedSeconds = ProcessInfo.processInfo.systemUptime - indexedStart
            #expect(indexed.finalized == baseline.finalized)
            #expect(cache.attributionCount == 0)
            print(
                "LIVE-GAP-ATTRIBUTION minutes=\(minutes) gaps=\(draft.speakerTimeline!.gaps.count) baseline_ms=\(baselineSeconds * 1000) indexed_ms=\(indexedSeconds * 1000)"
            )
        }
    }
}
