import Foundation
import Testing

@testable import GdayMeetings

struct LocalDiarizationTests {
    @Test func sourceNamesRequireKnownStemsAndSpeechRangesRemainBounded() {
        for (stem, expected) in [
            ("microphone", "microphone"), ("system", "system"), ("mic", "microphone"), ("system_mix", "system"),
            ("dynamic", "unknown"), ("systematic", "unknown"),
            ("microphone-compatible-00000000-0000-0000-0000-000000000001", "microphone"),
            ("system_mix-compatible-00000000-0000-0000-0000-000000000001", "system"),
            ("dynamic-compatible-00000000-0000-0000-0000-000000000001", "unknown"),
            ("mic-compatible-not-a-uuid", "unknown"),
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

    @Test func independentTurnsRetainFullSupportAndDistinctStableEvidence() throws {
        let meetingID = UUID()
        let speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Community-1")
        let first = LocalSpeakerTurn(
            track: "track0", label: speaker.label, start: 0, end: 14,
            sampleRange: .init(audioFile: "system.wav", source: "system", start: 0, end: 10),
            audioRevision: "fixture",
            voiceEmbedding: .init(type: .community1, values: [1] + [Double](repeating: 0, count: 255)))
        var second = first
        second.start = 16
        second.end = 19
        second.sampleRange = .init(audioFile: "system.wav", source: "system", start: 16, end: 19)
        second.voiceEmbedding = .init(type: .community1, values: [0, 1] + [Double](repeating: 0, count: 254))
        let result = LocalDiarizationResult(
            modelRevision: "fixture",
            ranges: [
                .init(track: "track0", label: speaker.label, start: 0, end: 14),
                .init(track: "track0", label: speaker.label, start: 16, end: 19),
            ], speakers: [speaker], turnSamples: [first, second])
        let examples = VoiceLibraryPreparation.turnExamples(result: result, meetingID: meetingID)
        #expect(examples.count == 2)
        #expect(examples[0].speakerID == speaker.id && examples[1].speakerID == speaker.id)
        #expect(examples[0].id != examples[1].id)
        #expect(examples[0].embeddings == [first.voiceEmbedding!])
        #expect(examples[1].embeddings == [second.voiceEmbedding!])
        #expect(examples[0].attributionTurn == .init(start: 0, end: 14))
        #expect(examples[0].range?.end == 10)
        #expect(examples[0].detectedSpeakerSpans == [.init(start: 0, end: 14)])
        #expect(examples.allSatisfy { $0.personID == nil && $0.review == .unassigned })
        let restored = try JSONDecoder().decode(LocalDiarizationResult.self, from: JSONEncoder().encode(result))
        let replay = VoiceLibraryPreparation.turnExamples(result: restored, meetingID: meetingID)
        #expect(replay.map(\.id) == examples.map(\.id))
        #expect(restored.turnSamples == result.turnSamples)
    }

    @Test func sampleSnappingRetainsFractionalAcousticTurnAndSupportChangesIdentity() {
        let speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Community-1")
        let start = 1.234567
        let sampleStart = (start * 16000).rounded(.down) / 16000
        var result = LocalDiarizationResult(
            modelRevision: "fixture", ranges: [.init(track: "track0", label: speaker.label, start: start, end: 15)],
            speakers: [speaker],
            turnSamples: [
                .init(
                    track: "track0", label: speaker.label, start: start, end: 15,
                    sampleRange: .init(
                        audioFile: "system.wav", source: "system", start: sampleStart, end: sampleStart + 10),
                    audioRevision: "r1")
            ])
        let meetingID = UUID()
        let first = VoiceLibraryPreparation.turnExamples(result: result, meetingID: meetingID)
        #expect(first.count == 1)
        result.ranges[0].end = 16
        result.turnSamples?[0].end = 16
        let revised = VoiceLibraryPreparation.turnExamples(result: result, meetingID: meetingID)
        #expect(revised.count == 1)
        #expect(first.first?.id != revised.first?.id)
    }

    @Test func unusableOrOverlappingTurnCannotCreateAttributionEvidence() {
        let speaker = MeetingSpeaker(label: "mic_01", track: "track0", providerName: "Community-1")
        let turn = LocalSpeakerTurn(
            track: "track0", label: speaker.label, start: 0, end: 3,
            sampleRange: .init(audioFile: "microphone.wav", source: "microphone", start: 0, end: 3),
            audioRevision: "fixture")
        var result = LocalDiarizationResult(
            modelRevision: "fixture", ranges: [.init(track: "track0", label: speaker.label, start: 0, end: 3)],
            speakers: [speaker], turnSamples: [turn])
        #expect(VoiceLibraryPreparation.turnExamples(result: result, meetingID: UUID()).count == 1)
        result.ranges[0].associationUncertain = true
        #expect(VoiceLibraryPreparation.turnExamples(result: result, meetingID: UUID()).isEmpty)
        result.ranges[0].associationUncertain = nil
        result.ranges.append(.init(track: "track0", label: "mic_02", start: 2, end: 4))
        #expect(VoiceLibraryPreparation.turnExamples(result: result, meetingID: UUID()).isEmpty)
        result.ranges.removeLast()
        result.turnSamples?[0].sampleRange?.end = 1
        #expect(VoiceLibraryPreparation.turnExamples(result: result, meetingID: UUID()).isEmpty)
    }

    @Test func cacheRetainsIndependentTurnMetadataAndInvalidatesPreviousPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = VoiceDiscoveryInput(
            meetingID: UUID(), audioFiles: ["system.wav"], audioRevisions: ["system.wav": "r1"])
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Community-1")
        speaker.independentTurnAttribution = true
        let restoredSpeaker = try JSONDecoder().decode(MeetingSpeaker.self, from: JSONEncoder().encode(speaker))
        #expect(restoredSpeaker == speaker)
        #expect(restoredSpeaker.independentTurnAttribution == true)
        let turn = LocalSpeakerTurn(
            track: "track0", label: speaker.label, start: 0, end: 3,
            sampleRange: .init(audioFile: "system.wav", source: "system", start: 0, end: 3), audioRevision: "r1")
        let result = LocalDiarizationResult(
            modelRevision: "fixture", ranges: [.init(track: "track0", label: speaker.label, start: 0, end: 3)],
            speakers: [speaker], turnSamples: [turn])
        let cache = VoiceDiscoveryCache()
        try await cache.save(result, input: input, configuration: .community, directory: directory)
        let loaded = try #require(try await cache.read(input: input, configuration: .community, directory: directory))
        #expect(loaded.turnSamples == [turn])
        #expect(loaded.speakers.first?.independentTurnAttribution == true)
        var previous = VoiceDiscoveryConfiguration.community
        previous.pipeline = previous.pipeline.replacingOccurrences(of: "independent-turn-v2", with: "speech-range-v1")
        #expect(try await cache.read(input: input, configuration: previous, directory: directory) == nil)
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
        let embedding = try #require(result.turnSamples?.compactMap(\.voiceEmbedding).first)
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

    @Test func recordedSpeakerReplacesSourcePlaceholderAndBecomesAssociable() {
        var meeting = Meeting()
        let placeholder = MeetingSpeaker(
            label: "mic", track: "microphone", providerName: "This Mac", sourcePlaceholder: .microphone)
        let detected = MeetingSpeaker(label: "mic_01", track: "track0", providerName: "Community-1")
        meeting.speakers = [placeholder]
        var row = TranscriptSegment(start: 0, end: 3, speaker: "mic", text: "Preserve these words.")
        row.speakerID = placeholder.id
        row.source = .microphone
        row.sourcePlaceholder = true
        row.associationUncertain = true
        meeting.transcript = [row]
        let result = LocalDiarizationResult(
            modelRevision: "fixture", ranges: [.init(track: "track0", label: detected.label, start: 0, end: 3)],
            speakers: [detected], trackSources: ["track0": "microphone"])
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1)
        #expect(updated.transcript[0].id == row.id)
        #expect(updated.transcript[0].text == row.text)
        #expect(updated.transcript[0].source == .microphone)
        #expect(updated.transcript[0].sourcePlaceholder == false)
        #expect(updated.transcript[0].associationUncertain == nil)
        #expect(updated.transcript[0].speakerID == detected.id)
        #expect(updated.speakers.map(\.id) == [detected.id])
    }

    @Test func reviewableAcousticClusterSurvivesWithoutDominatingATranscriptRow() {
        var meeting = Meeting()
        meeting.transcript = [.init(start: 0, end: 10, text: "A long mixed passage.")]
        var speaker = MeetingSpeaker(label: "mic_01", track: "track0", providerName: "Community-1")
        speaker.voiceEmbedding = .init(
            type: .community1, values: [1] + [Double](repeating: 0, count: 255))
        speaker.voiceSampleRange = .init(audioFile: "microphone.wav", source: "microphone", start: 0, end: 3)
        let result = LocalDiarizationResult(
            modelRevision: "fixture", ranges: [.init(track: "track0", label: speaker.label, start: 0, end: 3)],
            speakers: [speaker], trackSources: ["track0": "microphone"])
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1)
        #expect(updated.transcript == meeting.transcript)
        #expect(updated.speakers.map(\.id) == [speaker.id])
        #expect(updated.speakers.first?.voiceSampleRange == speaker.voiceSampleRange)
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
