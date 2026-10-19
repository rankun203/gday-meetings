import Foundation
import Testing

@testable import GdayMeetings

struct DiarizedTranscriptProjectionTests {
    private func row(_ text: String, words: [(String, Double, Double)]) -> TranscriptSegment {
        TranscriptSegment(
            start: words.first!.1, end: words.last!.2, text: text, source: .system,
            timing: .fromWords(
                text: text, words: words.map { .init(text: $0.0, start: $0.1, end: $0.2) }, granularity: .word))
    }
    private func result(_ ranges: [(String, Double, Double)]) -> LocalDiarizationResult {
        LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: ranges.map {
                .init(track: "track0", label: $0.0, start: $0.1, end: $0.2)
            },
            speakers: Array(Set(ranges.map(\.0))).sorted().map {
                MeetingSpeaker(label: $0, track: "track0", providerName: "Synthetic")
            }, trackSources: ["track0": "system"])
    }
    @Test func mixedTimingRetainsWholePassageAssignment() {
        let timed = row("Timed", words: [("Timed", 0, 1)])
        let untimed = TranscriptSegment(start: 2, end: 4, text: "Untimed passage", source: .system)
        let ambiguous = TranscriptSegment(start: 5, end: 7, text: "Two voices", source: .system)
        var meeting = Meeting()
        meeting.transcript = [timed, untimed, ambiguous]
        let analysis = result([("A", 0, 4), ("A", 5, 6), ("B", 6, 7)])
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        let saved = projected.transcript.first { $0.id == untimed.id }!
        #expect(saved.speaker == "A")
        #expect(saved.speakerID == analysis.speakers.first { $0.label == "A" }?.id)
        #expect(saved.timing == nil)
        #expect(saved.text == untimed.text && saved.start == untimed.start && saved.end == untimed.end)
        #expect(projected.transcript.first { $0.id == ambiguous.id } == ambiguous)
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1).transcript
                == projected.transcript)
    }

    @Test func mixedTimingKeepsManualAssignmentsAndSourceTracks() {
        var reviewed = MeetingSpeaker(label: "Reviewed", track: "system", providerName: "Synthetic")
        reviewed.personID = UUID()
        var protected = TranscriptSegment(start: 2, end: 3, text: "Reviewed passage", source: .system)
        protected.speakerID = reviewed.id
        let microphone = TranscriptSegment(start: 2, end: 3, text: "Microphone passage", source: .microphone)
        var meeting = Meeting()
        meeting.speakers = [reviewed]
        meeting.transcript = [row("Timed", words: [("Timed", 0, 1)]), protected, microphone]
        var analysis = result([("A", 0, 4)])
        let micSpeaker = MeetingSpeaker(label: "B", track: "track1", providerName: "Synthetic")
        analysis.trackSources["track1"] = "microphone"
        analysis.speakers.append(micSpeaker)
        analysis.ranges.append(.init(track: "track1", label: "B", start: 0, end: 4))
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 2)
        #expect(projected.transcript.first { $0.id == protected.id } == protected)
        #expect(projected.transcript.first { $0.id == microphone.id }?.speakerID == micSpeaker.id)
        #expect(projected.transcript.first { $0.id == microphone.id }?.timing == nil)
    }

    @Test func unresolvedWordsAndPunctuationGroupInsideOneAcousticGap() {
        var meeting = Meeting()
        let original = row("你好！", words: [("你", 1, 1.2), ("好", 1.2, 1.4), ("！", 1.4, 1.6)])
        meeting.transcript = [original]
        let analysis = result([("A", 4, 5)])
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript.count == 1)
        let saved = projected.transcript[0]
        #expect(saved.text == original.text)
        #expect(saved.timing == original.timing)
        #expect(saved.speakerID == nil)
        #expect(saved.sourcePlaceholder == true)
        #expect(saved.sourceSpans?.map(\.text).joined() == original.text)
        #expect(saved.sourceSpans?.map(\.rowID) == [original.id, original.id, original.id])
        #expect(saved.sourceSpans?.map { $0.range.location } == [0, 1, 2])
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1).transcript
                == projected.transcript)
    }

    @Test func unresolvedGroupingKeepsAcousticBoundariesAndOriginalRows() {
        var meeting = Meeting()
        meeting.transcript = [row("One two", words: [("One", 0, 1), ("two", 3, 4)])]
        let intervening = result([("A", 1.5, 2.5)])
        #expect(LocalDiarizationAssignment.applying(intervening, to: meeting, fileCount: 1).transcript.count == 2)
        meeting.transcript = [row("One", words: [("One", 0, 1)]), row("two", words: [("two", 1, 2)])]
        let later = result([("A", 4, 5)])
        #expect(LocalDiarizationAssignment.applying(later, to: meeting, fileCount: 1).transcript.count == 2)
    }

    @Test func unresolvedGroupingRequiresIdenticalAmbiguousIntervals() {
        var meeting = Meeting()
        meeting.transcript = [row("One two", words: [("One", 1, 2), ("two", 2, 3)])]
        let shared = result([("A", 0, 4), ("B", 0, 4)])
        let grouped = LocalDiarizationAssignment.applying(shared, to: meeting, fileCount: 1)
        #expect(grouped.transcript.count == 1)
        #expect(grouped.transcript[0].speakerID == nil)
        #expect(grouped.transcript[0].text == "One two")
        let separate = result([("A", 0, 4), ("B", 0, 2), ("B", 2, 4)])
        #expect(LocalDiarizationAssignment.applying(separate, to: meeting, fileCount: 1).transcript.count == 2)
        var speaker = MeetingSpeaker(
            label: "Reviewed", track: "track0", providerName: "Synthetic", manuallyAssigned: true)
        speaker.personID = UUID()
        meeting.speakers = [speaker]
        meeting.transcript[0].speakerID = speaker.id
        #expect(LocalDiarizationAssignment.applying(shared, to: meeting, fileCount: 1).transcript == meeting.transcript)
    }

    @Test func assignedGroupingPreservesSessionAndSourceBoundaries() {
        let session = UUID()
        var first = row("One", words: [("One", 0, 1)])
        var second = row("two", words: [("two", 1, 2)])
        first.session = session
        second.session = session
        first.analysisTrackID = "track0"
        second.analysisTrackID = "track0"
        var meeting = Meeting()
        meeting.transcript = [first, second]
        let analysis = result([("A", 0, 2)])
        let grouped = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(grouped.transcript.count == 1)
        #expect(grouped.transcript[0].text == "One two")
        #expect(grouped.transcript[0].session == session)

        second.session = UUID()
        meeting.transcript = [first, second]
        let differentSessions = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(differentSessions.transcript.count == 2)
        #expect(differentSessions.transcript.map(\.session) == [first.session, second.session])

        second.session = session
        second.source = .microphone
        meeting.transcript = [first, second]
        let differentSources = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(differentSources.transcript.count == 2)
        #expect(differentSources.transcript.map(\.source) == [first.source, second.source])
    }

    @Test func turnsSplitInsideRecognitionAndMergeAcrossRecognitionRows() {
        var meeting = Meeting()
        meeting.transcript = [
            row("One two", words: [("One", 0, 1), ("two", 1, 2)]),
            row("three", words: [("three", 2, 3)]),
        ]
        let analysis = result([("A", 0, 1), ("B", 1, 3)])
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript.map(\.text) == ["One", " two three"])
        #expect(projected.transcript.map(\.speaker) == ["A", "B"])
        #expect(projected.transcript[1].sourceSpans?.count == 2)
        let again = LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1)
        #expect(again.transcript == projected.transcript)
    }
    @Test func attributedTurnsRetainAssociationUncertaintyWhenGrouped() {
        var meeting = Meeting()
        meeting.transcript = [
            row("One two", words: [("One", 0, 1), ("two", 1, 2)]),
            row("three", words: [("three", 2, 3)]),
        ]
        var analysis = result([("A", 0, 2), ("B", 2, 3)])
        analysis.ranges[0].associationUncertain = true
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript.map(\.speaker) == ["A", "B"])
        #expect(projected.transcript[0].text == "One two")
        #expect(projected.transcript[0].associationUncertain == true)
        #expect(projected.transcript[1].associationUncertain == nil)
    }
    @Test func changedTextAndCoarseMixedRunAreNeverInventedWordTiming() {
        var meeting = Meeting()
        var edited = row("Original", words: [("Original", 0, 1)])
        edited.text = "Edited"
        meeting.transcript = [edited, row("A whole run", words: [("A whole run", 1, 4)])]
        let projected = LocalDiarizationAssignment.applying(
            result([("A", 0, 2), ("B", 2, 4)]), to: meeting, fileCount: 1)
        #expect(projected.transcript[0] == edited)
        #expect(projected.transcript[1].text == "A whole run")
        #expect(projected.transcript[1].sourcePlaceholder == true)
    }
    @Test func chineseAndUntimedLexicalGapKeepEveryCharacter() {
        var meeting = Meeting()
        meeting.transcript = [row("你好，缺字世界！", words: [("你好", 0, 1), ("世界", 2, 3)])]
        let projected = LocalDiarizationAssignment.applying(
            result([("A", 0, 1), ("B", 2, 3)]), to: meeting, fileCount: 1)
        #expect(projected.transcript.map(\.text).joined() == "你好，缺字世界！")
        #expect(projected.transcript.contains { $0.text == "，缺字" && $0.sourcePlaceholder == true })
    }
    @Test func zeroDurationLexicalGapKeepsSourceOrder() {
        var meeting = Meeting()
        meeting.transcript = [row("A missing B", words: [("A", 0, 1), ("B", 1, 2)])]
        let projected = LocalDiarizationAssignment.applying(result([("A", 0, 2)]), to: meeting, fileCount: 1)
        #expect(projected.transcript.map(\.text).joined() == "A missing B")
    }
    @Test func mergedPassageCanSplitAgainWithoutLosingOriginalAnchors() {
        var meeting = Meeting()
        meeting.transcript = [row("One", words: [("One", 0, 1)]), row("two", words: [("two", 1, 2)])]
        let mergedResult = result([("A", 0, 2)])
        let merged = LocalDiarizationAssignment.applying(mergedResult, to: meeting, fileCount: 1)
        let split = LocalDiarizationAssignment.applying(result([("A", 0, 1), ("B", 1, 2)]), to: merged, fileCount: 1)
        let again = LocalDiarizationAssignment.applying(mergedResult, to: split, fileCount: 1)
        #expect(again.transcript == merged.transcript)
        #expect(
            Set(again.transcript.flatMap { $0.sourceSpans ?? [] }.map(\.rowID)) == Set(meeting.transcript.map(\.id)))
    }
    @Test func overlappingSpeakersStayUnresolvedAndManualPassagesRemainIntact() {
        var meeting = Meeting()
        var manual = row("Keep", words: [("Keep", 0, 1)])
        let speaker = MeetingSpeaker(
            label: "Reviewed", track: "track0", providerName: "Synthetic", manuallyAssigned: true)
        manual.speakerID = speaker.id
        meeting.speakers = [speaker]
        meeting.transcript = [manual, row("Overlap", words: [("Overlap", 2, 3)])]
        let projected = LocalDiarizationAssignment.applying(
            result([("A", 0, 4), ("B", 2, 3)]), to: meeting, fileCount: 1)
        #expect(projected.transcript[0] == manual)
        #expect(projected.transcript[1].sourcePlaceholder == true)
    }

    @Test func preciseWordCanUseDominantAdjacentTurnWithoutChangingTiming() {
        var meeting = Meeting()
        let original = row("Boundary", words: [("Boundary", 0.8, 1.2)])
        meeting.transcript = [original]
        let analysis = result([("A", 0, 0.85), ("B", 0.85, 2)])
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript[0].speaker == "B")
        #expect(projected.transcript[0].associationUncertain == true)
        #expect(projected.transcript[0].timing == original.timing)
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1).transcript
                == projected.transcript)
        var coarse = original
        coarse.timing?.spans[0].granularity = .run
        meeting.transcript = [coarse]
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1).transcript[0].sourcePlaceholder
                == true)
        meeting.transcript = [original]
        let simultaneous = result([("A", 0.8, 0.85), ("B", 0.8, 2)])
        #expect(
            LocalDiarizationAssignment.applying(simultaneous, to: meeting, fileCount: 1).transcript[0].sourcePlaceholder
                == true)
    }

    @Test func gapFillRequiresShortBracketedSameSpeakerEvidence() {
        var meeting = Meeting()
        meeting.transcript = [row("brief", words: [("brief", 1.02, 1.08)])]
        let analysis = result([("A", 0, 1), ("A", 1.1, 2)])
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript[0].speaker == "A")
        #expect(projected.transcript[0].associationUncertain == true)
        #expect(projected.transcript[0].timing == meeting.transcript[0].timing)
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1).transcript
                == projected.transcript)
        for unsupported in [
            result([("A", 0, 1)]), result([("A", 0, 1), ("B", 1.1, 2)]),
            result([("A", 0, 1), ("A", 1.5, 2)]),
        ] {
            #expect(
                LocalDiarizationAssignment.applying(unsupported, to: meeting, fileCount: 1).transcript[0]
                    .sourcePlaceholder == true)
        }
    }

    @Test func singleVoiceAtWordEdgeRetainsInferredAttributionAndExactTiming() {
        for ranges in [[("A", 1.7, 3.0)], [("A", 0.0, 1.3)]] {
            var meeting = Meeting()
            let original = row("Boundary", words: [("Boundary", 1, 2)])
            meeting.transcript = [original]
            let analysis = result(ranges)
            let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
            #expect(projected.transcript[0].speaker == "A")
            #expect(projected.transcript[0].associationUncertain == true)
            #expect(projected.transcript[0].text == original.text)
            #expect(projected.transcript[0].timing == original.timing)
            #expect(projected.transcript[0].sourceSpans?.map(\.text).joined() == original.text)
            #expect(
                LocalDiarizationAssignment.applying(analysis, to: projected, fileCount: 1).transcript
                    == projected.transcript)
        }
    }

    @Test func edgeEvidenceDoesNotPromoteSliversCoarseRunsOrCompetingVoices() {
        var meeting = Meeting()
        let original = row("Boundary", words: [("Boundary", 1, 2)])
        meeting.transcript = [original]
        for unsupported in [
            result([("A", 1.96, 3)]), result([("A", 1.86, 3)]),
            result([("A", 2.02, 3)]), result([("A", 0, 1.1), ("B", 1.8, 3)]),
            result([("A", 1.8, 3), ("B", 1.9, 3)]),
        ] {
            #expect(
                LocalDiarizationAssignment.applying(unsupported, to: meeting, fileCount: 1).transcript[0]
                    .sourcePlaceholder == true)
        }
        var coarse = original
        coarse.timing?.spans[0].granularity = .run
        meeting.transcript = [coarse]
        #expect(
            LocalDiarizationAssignment.applying(result([("A", 1.8, 3)]), to: meeting, fileCount: 1).transcript[0]
                .sourcePlaceholder == true)
        meeting.transcript = [row("Long", words: [("Long", 0, 2)])]
        #expect(
            LocalDiarizationAssignment.applying(result([("A", 1.6, 3)]), to: meeting, fileCount: 1).transcript[0]
                .sourcePlaceholder == true)
        // Passes the relative and absolute support gates but has an excessive edge.
        meeting.transcript = [row("Distant", words: [("Distant", 0, 1.4)])]
        #expect(
            LocalDiarizationAssignment.applying(result([("A", 1.0, 3)]), to: meeting, fileCount: 1).transcript[0]
                .sourcePlaceholder == true)
        meeting.transcript = [row("Tiny", words: [("Tiny", 1, 1.2)])]
        #expect(
            LocalDiarizationAssignment.applying(result([("A", 1.15, 2)]), to: meeting, fileCount: 1).transcript[0]
                .sourcePlaceholder == true)
    }

    @Test func edgeInferenceDoesNotOverwriteManualAttributionOrBecomeCertainWhenGrouped() {
        var meeting = Meeting()
        let manual = MeetingSpeaker(
            label: "Reviewed", track: "track0", providerName: "Synthetic", manuallyAssigned: true)
        var protectedRow = row("Keep", words: [("Keep", 1, 2)])
        protectedRow.speakerID = manual.id
        meeting.speakers = [manual]
        meeting.transcript = [protectedRow]
        let analysis = result([("A", 1.7, 4)])
        #expect(
            LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1).transcript == meeting.transcript)
        meeting.speakers = []
        meeting.transcript = [row("Boundary then", words: [("Boundary", 1, 2), ("then", 2, 3)])]
        let projected = LocalDiarizationAssignment.applying(analysis, to: meeting, fileCount: 1)
        #expect(projected.transcript.count == 2)
        #expect(projected.transcript.map(\.associationUncertain) == [true, nil])
        #expect(projected.transcript.map(\.text).joined() == meeting.transcript[0].text)
    }
}
