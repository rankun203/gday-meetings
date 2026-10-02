import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LiveTranscriptDisplayCacheTests {
    private func history(count: Int) -> [LiveTranscriptPhrase] {
        let session = UUID()
        return (0..<count).map {
            .init(
                session: session, source: .microphone, start: Double($0 * 2), end: Double($0 * 2) + 1.8,
                text: "Sample words")
        }
    }

    @Test func partialAppendAndFinalizationOnlyRebuildTail() {
        let meetingID = UUID()
        let cache = LiveTranscriptDisplayCache()
        var finalized = history(count: 900)
        var partial = LiveTranscriptPhrase(
            session: finalized[0].session, source: .microphone,
            start: 1800, end: 1801, text: "Current words")
        func check() {
            let actual = cache.snapshot(meetingID: meetingID, finalized: finalized, partials: [partial], people: [])
            let reference = LiveTranscriptDisplay.snapshot(finalized: finalized, partials: [partial], people: [])
            #expect(actual.rows == reference.rows)
            #expect(actual.phrases == reference.phrases)
        }
        check()
        partial.text = "Current revised words"
        check()
        #expect(cache.rebuiltParagraphCount <= 3)
        finalized.append(partial)
        partial = .init(session: partial.session, source: .microphone, start: 1801.2, end: 1802, text: "Next words")
        check()
        #expect(cache.rebuiltParagraphCount <= 3)
        // A late source/identity revision may change paragraph boundaries.
        finalized[20].speakerIdentity = UUID()
        finalized[20].diarizationLabel = "mic_02"
        check()
    }

    @Test func historicalEditPeopleRenameAndMeetingReplacementMatchReference() {
        let cache = LiveTranscriptDisplayCache()
        var draft = LiveTranscriptResolutionCacheTests.fixture(minutes: 2)
        var people = [Person(name: "Sample Person")]
        func check() {
            let resolved = draft.resolvedRows()
            let actual = cache.snapshot(
                meetingID: draft.meetingID, finalized: resolved.finalized,
                partials: resolved.partials, people: people, overrides: draft.overrides ?? [])
            let reference = LiveTranscriptDisplay.snapshot(
                finalized: resolved.finalized,
                partials: resolved.partials, people: people, overrides: draft.overrides ?? [])
            #expect(actual.rows == reference.rows)
            #expect(actual.phrases == reference.phrases)
        }
        check()
        let phrase = draft.phrases[10]
        draft.updateText("Edited sample.", for: phrase)
        draft.assignPerson(people[0].id, for: phrase)
        check()
        people[0].name = "Renamed Person"
        check()
        draft = LiveTranscriptResolutionCacheTests.fixture(minutes: 1)
        check()
    }

    @Test func tiedStartRowsSurviveLaterTailRevision() {
        let cache = LiveTranscriptDisplayCache()
        let meetingID = UUID()
        let session = UUID()
        var rows: [LiveTranscriptPhrase] = [
            .init(session: session, source: .microphone, start: 0, end: 1, text: "First."),
            .init(session: session, source: .microphone, start: 0, end: 2, text: "Second."),
            .init(session: session, source: .microphone, start: 10, end: 11, text: "Third."),
        ]
        _ = cache.snapshot(meetingID: meetingID, finalized: rows, partials: [], people: [])
        rows[2].text = "Changed third."
        let actual = cache.snapshot(meetingID: meetingID, finalized: rows, partials: [], people: [])
        let reference = LiveTranscriptDisplay.snapshot(finalized: rows, partials: [], people: [])
        #expect(actual.rows == reference.rows)
        #expect(actual.phrases == reference.phrases)
    }

    @Test func nativeDiffRetainsPrefixWhenTailIdentityChanges() {
        let values = history(count: 4)
        let previous = LiveTranscriptDisplay.rows(finalized: [], partials: values, people: [])
        var changed = values
        changed[3].id = UUID()
        changed.append(.init(session: values[0].session, source: .system, start: 9, end: 10, text: "New sample"))
        let current = LiveTranscriptDisplay.rows(finalized: [], partials: changed, people: [])
        let delta = TranscriptRowUpdate(previous: previous, current: current)
        #expect(delta.removed == IndexSet(integer: 3))
        #expect(delta.inserted == IndexSet(3..<5))
        // The previous active partial loses its recognition highlight.
        #expect(delta.changed.isSubset(of: IndexSet(0..<3)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
    func benchmarkDisplayTailUpdates() {
        for minutes in [5, 45, 120] {
            let finalized = history(count: minutes * 30)
            let meetingID = UUID()
            let cache = LiveTranscriptDisplayCache()
            var partial = LiveTranscriptPhrase(
                session: finalized[0].session, source: .microphone,
                start: Double(minutes * 60), end: Double(minutes * 60) + 1, text: "Current sample")
            _ = cache.snapshot(meetingID: meetingID, finalized: finalized, partials: [partial], people: [])
            var baseline = 0.0
            var incremental = 0.0
            for update in 0..<10 {
                partial.text = "Current sample \(update)"
                var start = ProcessInfo.processInfo.systemUptime
                let reference = LiveTranscriptDisplay.snapshot(finalized: finalized, partials: [partial], people: [])
                baseline += ProcessInfo.processInfo.systemUptime - start
                start = ProcessInfo.processInfo.systemUptime
                let actual = cache.snapshot(meetingID: meetingID, finalized: finalized, partials: [partial], people: [])
                incremental += ProcessInfo.processInfo.systemUptime - start
                #expect(actual.rows == reference.rows)
                #expect(actual.phrases == reference.phrases)
                #expect(cache.rebuiltParagraphCount <= 3)
            }
            print(
                "LIVE-DISPLAY minutes=\(minutes) updates=10 baseline_ms=\(baseline * 1000) incremental_ms=\(incremental * 1000)"
            )
        }
    }
}
