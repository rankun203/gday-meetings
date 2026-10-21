import Foundation
import Testing

@testable import GdayMeetings

struct VoiceSampleTranscriptTests {
    @Test func transcriptRequestIgnoresReviewChangesButTracksAudioChanges() {
        let meeting = Meeting(title: "Synthetic conversation")
        var sample = example(meeting: meeting)
        let request = VoiceSampleTranscript.Request(sample)
        sample.suggestedPersonID = UUID()
        sample.review = .suggested
        sample.personID = UUID()
        sample.review = .confirmed
        #expect(VoiceSampleTranscript.Request(sample) == request)
        sample.audioRevision = "replacement"
        #expect(VoiceSampleTranscript.Request(sample) != request)
        sample.audioRevision = "synthetic"
        sample.end = 5
        #expect(VoiceSampleTranscript.Request(sample) != request)
    }

    private func example(meeting: Meeting, start: Double = 1, end: Double = 4) -> VoiceExample {
        VoiceExample(
            meetingID: meeting.id, speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic", start: start, end: end)
    }

    @Test func exactSourceAndOverlappingTimeExcludeSimultaneousOtherTrackAndUnknownMix() throws {
        var meeting = Meeting(audioFiles: ["microphone.wav", "system.wav"])
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "track0", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 2, text: "Overlapping system passage.", source: .system),
            .init(start: 1, end: 3, text: "Microphone passage.", source: .microphone),
            .init(start: 1, end: 3, text: "Unresolved mixed passage."),
            .init(start: 4, end: 6, text: "Touches the end.", source: .system),
            .init(start: 1, end: 3, text: "Exact analysis file.", analysisTrackID: "track1"),
            .init(start: 1, end: 3, text: "Explicit row source.", speakerID: speaker.id, source: .system),
        ]
        let passages = try VoiceSampleTranscript.passages(for: example(meeting: meeting), meeting: meeting)
        #expect(
            Set(passages.map(\.text))
                == ["Overlapping system passage.", "Exact analysis file.", "Explicit row source."])
        #expect(passages.allSatisfy { $0.timing == nil })
    }

    @Test func singleImportedMixRemainsReadableWhileAmbiguousSameSourceFilesDoNotGuess() throws {
        var meeting = Meeting(audioFiles: ["imported.wav"])
        meeting.transcript = [.init(start: 0, end: 5, text: "Existing mixed transcript.", source: .system)]
        var sample = example(meeting: meeting)
        sample.audioFile = "imported.wav"
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).count == 1)
        meeting.audioFiles = ["system.wav", "system.m4a"]
        sample.audioFile = "system.wav"
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).isEmpty)
        meeting.transcript[0].analysisTrackID = "track0"
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).count == 1)
        meeting.audioFiles = ["system.wav"]
        meeting.transcript[0].analysisTrackID = nil
        meeting.transcript[0].source = .microphone
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).isEmpty)
        meeting.transcript[0].analysisTrackID = "track1"
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).isEmpty)
    }

    @Test func disjointAudioKeepsNativeWordOffsetsAndNeverIncludesSkippedWords() throws {
        var meeting = Meeting(audioFiles: ["system.wav"])
        let text = "One gap three."
        meeting.transcript = [
            .init(
                start: 0, end: 6, text: text,
                timing: .fromWords(
                    text: text,
                    words: [
                        .init(text: "One", start: 0, end: 1),
                        .init(text: "gap", start: 2, end: 3),
                        .init(text: "three.", start: 4, end: 5),
                    ], granularity: .word))
        ]
        var sample = example(meeting: meeting, start: 0, end: 5)
        sample.spans = [.init(start: 0, end: 1), .init(start: 4, end: 5)]
        let passages = try VoiceSampleTranscript.passages(for: sample, meeting: meeting)
        #expect(passages.map(\.text) == ["One", "three."])
        #expect(passages.allSatisfy { $0.timing?.spans.allSatisfy { $0.granularity == .word } == true })
        #expect(passages[0].highlightedRanges(at: 0.5) == [.init(location: 0, length: 3)])
        #expect(passages[0].highlightedRanges(at: 1).isEmpty)
        #expect(passages[1].highlightedRanges(at: 2.5).isEmpty)
        #expect(passages[1].highlightedRanges(at: 4.5) == [.init(location: 0, length: 6)])
    }

    @Test func timingFallbackKeepsWholeTextWithoutHighlighting() throws {
        var meeting = Meeting(audioFiles: ["system.wav"])
        let text = "A complete passage extends beyond the sample."
        meeting.transcript = [.init(start: 0, end: 9, text: text)]
        var sample = example(meeting: meeting, start: 1, end: 7)
        sample.spans = [.init(start: 1, end: 2), .init(start: 6, end: 7)]
        var passage = try #require(VoiceSampleTranscript.passages(for: sample, meeting: meeting).first)
        #expect(passage.text == text)
        #expect(passage.highlightedRanges(at: 1.5).isEmpty)
        #expect(passage.highlightedRanges(at: 4).isEmpty)
        meeting.transcript[0].timing = .init(
            text: "Earlier text",
            spans: [.init(range: .init(location: 0, length: 7), start: 0, end: 3, granularity: .word)])
        passage = try #require(VoiceSampleTranscript.passages(for: sample, meeting: meeting).first)
        #expect(passage.text == text && passage.timing == nil)
    }

    @Test func nativeRunTimingNeverBecomesFabricatedWordTiming() throws {
        var meeting = Meeting(audioFiles: ["system.wav"])
        let text = "A native phrase."
        meeting.transcript = [
            .init(
                start: 0, end: 5, text: text,
                timing: .fromWords(text: text, words: [.init(text: text, start: 0, end: 5)], granularity: .run))
        ]
        let passage = try #require(
            VoiceSampleTranscript.passages(for: example(meeting: meeting), meeting: meeting).first)
        #expect(passage.text == text)
        #expect(passage.timing?.spans.count == 1)
        #expect(passage.highlightedRanges(at: 2).isEmpty)
    }

    @Test func unicodeHighlightUsesSavedUTF16OffsetsAndMissingTextStaysUnavailable() throws {
        var meeting = Meeting(audioFiles: ["system.wav"])
        let text = "Hi 🌏 café"
        meeting.transcript = [
            .init(
                start: 0, end: 4, text: text,
                timing: .fromWords(
                    text: text,
                    words: [
                        .init(text: "Hi", start: 0, end: 1), .init(text: "🌏", start: 1, end: 2),
                        .init(text: "café", start: 2, end: 3),
                    ], granularity: .word))
        ]
        let sample = example(meeting: meeting, start: 0, end: 4)
        let passage = try #require(VoiceSampleTranscript.passages(for: sample, meeting: meeting).first)
        #expect(passage.highlightedRanges(at: 1.5) == [.init(location: 3, length: 2)])
        #expect(passage.highlightedRanges(at: 2.5) == [.init(location: 6, length: 4)])
        meeting.transcript = []
        #expect(try VoiceSampleTranscript.passages(for: sample, meeting: meeting).isEmpty)
    }

    @Test func playbackHighlightRequiresExactRecordingFileAndExcerptSession() {
        let meeting = Meeting(audioFiles: ["system.wav"])
        let sample = example(meeting: meeting)
        #expect(
            VoiceSampleTranscript.playbackTime(
                for: sample, meetingID: meeting.id, audioFile: "system.wav", excerptRanges: [1..<4], time: 2) == 2)
        #expect(
            VoiceSampleTranscript.playbackTime(
                for: sample, meetingID: UUID(), audioFile: "system.wav", excerptRanges: [1..<4], time: 2) == nil)
        #expect(
            VoiceSampleTranscript.playbackTime(
                for: sample, meetingID: meeting.id, audioFile: "microphone.wav", excerptRanges: [1..<4], time: 2) == nil
        )
        #expect(
            VoiceSampleTranscript.playbackTime(
                for: sample, meetingID: meeting.id, audioFile: "system.wav", excerptRanges: [0..<5], time: 2) == nil)
        #expect(
            VoiceSampleTranscript.playbackTime(
                for: sample, meetingID: meeting.id, audioFile: "system.wav", excerptRanges: [1..<4], time: 4) == nil)
    }
}
