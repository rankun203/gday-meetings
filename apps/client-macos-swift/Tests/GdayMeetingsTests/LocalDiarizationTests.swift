import Foundation
import Testing

@testable import GdayMeetings

struct LocalDiarizationTests {
    @Test func sourceNamesRequireKnownStemsAndSpeechRangesRemainBounded() {
        for (stem, expected) in [
            ("microphone", "microphone"), ("system", "system"), ("mic", "microphone"), ("system_mix", "system"),
            ("dynamic", "unknown"), ("systematic", "unknown"),
        ] {
            #expect(
                LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: "/synthetic/" + stem + ".wav"))
                    == expected)
        }
        #expect(LocalDiarizationInputPolicy.speechSamples(start: 1, end: 4, sampleCount: 80_000) == 16_000..<64_000)
        #expect(LocalDiarizationInputPolicy.speechSamples(start: 0, end: 20, sampleCount: 320_000) == 0..<160_000)
        for (start, end) in [
            (Double.nan, 3), (0, Double.infinity), (-1, 2), (0, 1), (4, 3), (0, 6),
            (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
        ] {
            #expect(LocalDiarizationInputPolicy.speechSamples(start: start, end: end, sampleCount: 80_000) == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_LOCAL_COMMUNITY_TEST"] == "1"))
    @MainActor func actualModelsLabelSyntheticSpeechAndExtractTypedVoice() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["GDAY_LOCAL_MODEL_TEST_ROOT"]))
        let audio = URL(fileURLWithPath: try #require(environment["GDAY_LOCAL_SYNTHETIC_AUDIO"]))
        let manager = LocalModelManager(root: root)
        let lease = try await manager.acquire(.community1)
        defer { manager.release(lease) }
        let result = try await CommunityDiarizationWorker().run(files: [audio], lease: lease, recognize: true)
        #expect(!result.ranges.isEmpty)
        #expect(result.ranges.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        let embedding = try #require(result.speakers.compactMap(\.voiceEmbedding).first)
        #expect(embedding.isValid)
        #expect(embedding.type == .community1)
        #expect(embedding.values.count == 256)
    }

    @Test func labelsPreserveEditedTextAndExistingPeople() {
        let person = UUID()
        let attributed = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "This Mac", personID: person)
        let unknown = MeetingSpeaker(label: "sys_01", track: "system", providerName: "This Mac")
        let detected = MeetingSpeaker(label: "sys_02", track: "track1", providerName: "Community-1")
        var meeting = Meeting()
        meeting.speakers = [attributed, unknown]
        meeting.transcript = [
            .init(start: 0, end: 3, speaker: attributed.label, text: "A corrected passage.", speakerID: attributed.id),
            .init(start: 4, end: 7, speaker: unknown.label, text: "Another corrected passage.", speakerID: unknown.id),
        ]
        let result = LocalDiarizationResult(
            modelRevision: "fixture",
            ranges: [
                .init(track: "track1", label: detected.label, start: 4, end: 7)
            ], speakers: [detected], trackSources: ["track0": "microphone", "track1": "system"])
        let revised = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 2)
        #expect(revised.transcript.map(\.text) == meeting.transcript.map(\.text))
        #expect(revised.transcript.map(\.id) == meeting.transcript.map(\.id))
        #expect(revised.transcript[0].speakerID == attributed.id)
        #expect(revised.speakers.first(where: { $0.id == attributed.id })?.personID == person)
        #expect(revised.transcript[1].speakerID == detected.id)
    }

    @Test func overlapAndUnknownTrackDoNotGuessOneSpeaker() {
        let first = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Community-1")
        let second = MeetingSpeaker(label: "sys_02", track: "track0", providerName: "Community-1")
        var meeting = Meeting()
        meeting.transcript = [.init(start: 0, end: 3, speaker: "", text: "Overlapping voices.")]
        let result = LocalDiarizationResult(
            modelRevision: "fixture",
            ranges: [
                .init(track: "track0", label: first.label, start: 0, end: 3),
                .init(track: "track0", label: second.label, start: 0, end: 3),
            ], speakers: [first, second])
        #expect(LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1).transcript == meeting.transcript)
        var oneSpeaker = result
        oneSpeaker.ranges.removeLast()
        #expect(
            LocalDiarizationAssignment.applying(oneSpeaker, to: meeting, fileCount: 2).transcript == meeting.transcript)
    }
}
