import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ProviderTimedTextTests {
    private var entry: [String: Any] {
        [
            "start": 0.0, "end": 3.0, "text": "  Hello, world!\n",
            "words": [
                ["word": "Hello,", "start": 0.2, "end": 1.0],
                ["word": "world!", "start": 1.2, "end": 2.0],
            ],
        ]
    }

    @Test func bothRemoteAdaptersPreserveIdenticalTimingAndExactText() throws {
        let tracks = ["system": ["segments": [entry]]]
        let server: [String: Any] = [
            "status": "COMPLETED",
            "outputs": [["type": "TRANSCRIPT_OUTPUT", "body": ["tracks": tracks]]],
        ]
        let worker: [String: Any] = ["status": "COMPLETED", "output": ["tracks": tracks]]
        guard case .complete(let serverRows) = try GdayServerService.parseTask(server),
            case .complete(let workerRows) = try RunPodProvider.parseStatus(worker)
        else {
            Issue.record("Expected completed transcripts")
            return
        }
        #expect(serverRows == workerRows)
        let timing = try #require(serverRows.first?.timing)
        #expect(timing.text == "  Hello, world!\n")
        #expect(timing.spans.count == 2)
        #expect(timing.spans[0].range.location == 2)
        #expect(timing.spans[0].range.length == 6)
        #expect(timing.spans[0].granularity == .word)
        #expect(timing.spans[1].start == 1.2)
        let result = SpeakerRecognition.result(
            serverRows, attempt: .init(provider: ServiceProvider(kind: .runpod), meeting: Meeting()), people: [])
        #expect(result.segments.first?.text == timing.text)
        #expect(result.segments.first?.timing == timing)
    }

    @Test func missingOrInvalidOptionalTimingDoesNotInventAlignment() {
        let examples: [Any] = [
            [],
            [["word": "Hello,"]],
            [["word": "Hello,", "start": Double.nan, "end": 1.0]],
            [["word": "Hello,", "start": 1.0, "end": 0.0]],
            [["word": "Hello,", "start": 1.0, "end": 4.0]],
            [["word": "Other", "start": 0.0, "end": 1.0]],
        ]
        for words in examples {
            var value = entry
            value["words"] = words
            #expect(ServerTranscriptSegment.wordTiming(value, text: "  Hello, world!\n") == nil)
        }
        #expect(ServerTranscriptSegment.wordTiming([:], text: "Unaligned") == nil)
    }

    @Test func partialAlignmentKeepsRepeatedUntimedWordUnassigned() throws {
        let entry: [String: Any] = [
            "start": 0.0, "end": 3.0,
            "words": [
                ["word": "Yes"],
                ["word": "Yes", "start": 1.0, "end": 2.0],
                ["word": "again", "start": NSNull(), "end": NSNull()],
            ],
        ]
        let timing = try #require(ServerTranscriptSegment.wordTiming(entry, text: "Yes Yes again"))
        #expect(timing.spans.count == 1)
        #expect(timing.spans[0].range.location == 4)
        #expect(timing.spans[0].range.length == 3)
        #expect(timing.text == "Yes Yes again")
    }

    @Test func unlabeledProviderRowsRetainTheirSubmittedSource() {
        var attempt = ProviderTranscriptionAttempt(provider: ServiceProvider(kind: .runpod), meeting: Meeting())
        attempt.inputs = [
            .init(url: URL(fileURLWithPath: "/synthetic/mic.wav"), trackName: "track0", sourceType: "mic", channels: 1),
            .init(
                url: URL(fileURLWithPath: "/synthetic/system.wav"), trackName: "track1", sourceType: "system_mix",
                channels: 1),
        ]
        let rows: [ServerTranscriptSegment] = [
            .init(start: 0, end: 1, text: "One", speaker: nil, track: "track0"),
            .init(start: 0, end: 1, text: "Two", speaker: nil, track: "track1"),
            .init(start: 0, end: 1, text: "Three", speaker: nil, track: "unknown"),
        ]
        let result = SpeakerRecognition.result(rows, attempt: attempt, people: [])
        #expect(result.segments.map(\.source) == [.microphone, .system, nil])
        #expect(result.speakers.isEmpty)
    }

    @Test func invalidWordTimingPreservesValidNeighborsAndRepeatedOffsets() throws {
        for invalid: [String: Any] in [
            ["start": 1.0, "end": 1.0],
            ["start": Double.nan, "end": 2.0],
            ["start": 1.0, "end": 9.0],
            ["start": NSNull(), "end": NSNull()],
        ] {
            var middle = invalid
            middle["word"] = "Yes"
            let entry: [String: Any] = [
                "start": 0.0, "end": 4.0,
                "words": [
                    ["word": "Yes", "start": 0.1, "end": 0.5], middle,
                    ["word": "Yes", "start": 2.0, "end": 3.0],
                ],
            ]
            let timing = try #require(ServerTranscriptSegment.wordTiming(entry, text: "Yes Yes Yes"))
            #expect(timing.spans.map(\.range.location) == [0, 8])
            #expect(timing.spans.map(\.start) == [0.1, 2.0])
            #expect(timing.isValid)
        }
    }

    @Test func unmatchedWordKeepsOnlySafelyAnchoredPrefix() throws {
        let entry: [String: Any] = [
            "start": 0.0, "end": 4.0,
            "words": [
                ["word": "Yes", "start": 0.1, "end": 0.5],
                ["word": "Missing", "start": 1.0, "end": 2.0],
                ["word": "Yes", "start": 2.0, "end": 3.0],
            ],
        ]
        let timing = try #require(ServerTranscriptSegment.wordTiming(entry, text: "Yes Yes Yes"))
        #expect(timing.spans.count == 1)
        #expect(timing.spans[0].range.location == 0)
    }
}
