import Foundation
import Testing

@testable import GdayMeetings

struct LiveStreamResetGrowthTests {
    @Test func historicalResetIdentitiesDoNotAccumulateInAttribution() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        let session = UUID()
        var expected: [UUID] = []
        for reset in 0..<300 {
            let generation = UUID()
            let start = Double(reset * 2)
            let speakers = (0..<8).map {
                LiveSpeakerIdentity(
                    id: UUID(), source: .system, generation: generation, slot: $0,
                    model: "synthetic", revision: "1")
            }
            stream.accept(
                .init(
                    source: .system, generation: generation, sequence: 0, speakers: speakers,
                    intervals: [.init(speakerID: speakers[0].id, start: start, end: start + 1)],
                    start: start, end: start + 2))
            let phrase = LiveTranscriptPhrase(
                session: session, source: .system, start: start, end: start + 1,
                text: "Synthetic words",
                words: [
                    .init(text: "Synthetic", start: start, end: start + 0.5),
                    .init(text: "words", start: start + 0.5, end: start + 1),
                ])
            stream.accept(phrase, final: true)
            expected.append(speakers[0].id)
            stream.accept(.init(source: .system, start: start + 1, end: start + 2, reason: "Synthetic reset"))
            #expect(stream.hotSpeakerCount <= 26)
        }
        stream.finish()
        #expect(stream.snapshot.phrases.map(\.speakerIdentity) == expected.map(Optional.some))
    }

    @Test func indexedEvidenceContainsOnlyRelevantIdentitiesAndKeepsUnknownSourceSemantics() {
        let generation = UUID()
        let speakers = (0..<8000).map {
            LiveSpeakerIdentity(
                id: UUID(), source: .system, generation: generation, slot: $0,
                model: "synthetic", revision: "1")
        }
        let timeline = LiveSpeakerTimeline(
            speakers: speakers,
            intervals: [.init(speakerID: speakers.last!.id, start: 1, end: 3)])
        let phrase = LiveTranscriptPhrase(session: UUID(), source: .system, start: 1, end: 3, text: "Words")
        let index = LiveSpeakerIntervalIndex(timeline)
        let evidence = index.evidence(for: phrase, preceding: nil)
        #expect(evidence.speakers.count == 1)
        #expect(evidence.attributing(phrase) == timeline.attributing(phrase))
        var outside = phrase
        outside.start = 4
        outside.end = 5
        outside.personID = UUID()
        let unknown = index.evidence(for: outside, preceding: nil)
        #expect(unknown.speakers.count == 1)
        #expect(unknown.attributing(outside) == timeline.attributing(outside))
        #expect(unknown.attributing(outside).first?.personID == nil)
    }

    @Test func pruningPreservesSharedSourceUnknownSpeechSemantics() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone, .system])
        let generation = UUID()
        let systemOnly = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: generation, slot: 0,
            model: "synthetic", revision: "1")
        let shared = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: generation, slot: 1,
            model: "synthetic", revision: "1", additionalSources: [.microphone])
        var timeline = LiveSpeakerTimeline(speakers: [systemOnly, shared])
        timeline.cursors = LiveAudioSource.allCases.map {
            .init(source: $0, generation: UUID(), sequence: 0, end: 100, final: false)
        }
        stream.replaceObservationTimeline(timeline)
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 99, end: 100,
            text: "Unknown voice", personID: UUID())
        stream.accept(phrase, final: true)
        stream.finish()
        #expect(stream.snapshot.phrases.first?.personID == nil)
    }

    @Test func gapBatchRefreshesOnceAndDuplicateGapDoesNotRefresh() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone, .system])
        let gaps: [LiveTranscriptGap] = [
            .init(source: .microphone, start: 1, end: 2, reason: "Synthetic gap"),
            .init(source: .system, start: 1, end: 2, reason: "Synthetic gap"),
        ]
        let before = stream.revision
        stream.accept(gaps)
        #expect(stream.revision == before + 1)
        stream.accept(gaps)
        #expect(stream.revision == before + 1)
    }
}
