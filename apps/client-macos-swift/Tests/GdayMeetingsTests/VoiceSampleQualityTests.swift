import Foundation
import Testing

@testable import GdayMeetings

struct VoiceSampleQualityTests {
    private func example() -> VoiceExample {
        .init(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic-v1", start: 0, end: 2, origin: .discovery)
    }

    private func assessed(_ samples: [Float]) -> VoiceExample {
        var value = example()
        value.sampleQuality = VoiceSampleQuality.assess(
            range: value.range!, audioRevision: value.audioRevision!, scanConfiguration: "synthetic-scan-v1",
            samples: samples)
        return value
    }

    @Test func pcmMetricsMatchIndependentReferenceCounts() throws {
        // Reference calculation uses absolute-value counts divided by 32,000;
        // values avoid floating point threshold ambiguity.
        let samples =
            [Float](repeating: 0, count: 16000)
            + [Float](repeating: 1, count: 320) + [Float](repeating: 0.25, count: 15680)
        let quality = try #require(assessed(samples).currentSampleQuality)
        #expect(quality.sampleCount == 32000)
        #expect(quality.nearSilentFraction == 0.5)
        #expect(quality.fullScaleFraction == 0.01)
        #expect(quality.issue == .audioAtFullScale)
        #expect(assessed([Float](repeating: 0, count: 32000)).currentSampleQuality?.issue == .nearSilentAudio)
        #expect(assessed([Float](repeating: 0.25, count: 32000)).currentSampleQuality?.issue == nil)
        let negative = try #require(assessed([Float](repeating: -1, count: 32000)).currentSampleQuality)
        #expect(negative.nearSilentFraction == 0)
        #expect(negative.fullScaleFraction == 1)
        #expect(negative.issue == .audioAtFullScale)
    }

    @Test func invalidAndIncompletePCMRemainsUnassessed() {
        #expect(assessed([]).currentSampleQuality == nil)
        #expect(assessed([Float](repeating: 0, count: 16000)).currentSampleQuality == nil)
        var samples = [Float](repeating: 0, count: 32000)
        samples[50] = .nan
        #expect(assessed(samples).currentSampleQuality == nil)
        samples[50] = .infinity
        #expect(assessed(samples).currentSampleQuality == nil)
    }

    @Test func shortSavedSpeechHasAnExplicitDurationIssue() {
        var value = example()
        value.end = 1
        value.sampleQuality = VoiceSampleQuality.assess(
            range: value.range!, audioRevision: value.audioRevision!, scanConfiguration: "synthetic-scan-v1",
            samples: [Float](repeating: 0.25, count: 16000))
        #expect(value.currentSampleQuality?.issue == .shortSample)
    }

    @Test func float32ThresholdNeighborsMatchIndependentReference() throws {
        let silence = VoiceSampleQuality.nearSilentThreshold
        let silentBoundary =
            [Float](repeating: silence.nextDown, count: 10000)
            + [Float](repeating: silence, count: 10000) + [Float](repeating: silence.nextUp, count: 12000)
        let quiet = try #require(assessed(silentBoundary).currentSampleQuality)
        #expect(quiet.nearSilentFraction == 0.625)
        let peak = VoiceSampleQuality.fullScaleThreshold
        let peakBoundary =
            [Float](repeating: peak.nextDown, count: 10000)
            + [Float](repeating: peak, count: 10000) + [Float](repeating: peak.nextUp, count: 12000)
        let loud = try #require(assessed(peakBoundary).currentSampleQuality)
        #expect(loud.fullScaleFraction == 0.6875)
        let negative = try #require(assessed(peakBoundary.map { -$0 }).currentSampleQuality)
        #expect(negative.fullScaleFraction == 0.6875)
    }

    @Test func cachedAssessmentRequiresIdenticalAudioRangeAndPolicy() throws {
        let original = assessed([Float](repeating: 0, count: 32000))
        var changed = original
        changed.audioRevision = "synthetic-v2"
        #expect(changed.currentSampleQuality == nil)
        changed = original
        changed.start = 0.01
        #expect(changed.currentSampleQuality == nil)
        changed = original
        changed.sampleQuality?.policy = "old-policy"
        #expect(changed.currentSampleQuality == nil)
        changed = original
        changed.audioFile = "other.wav"
        #expect(changed.currentSampleQuality == nil)
        let restored = try JSONDecoder().decode(VoiceExample.self, from: JSONEncoder().encode(original))
        #expect(restored.currentSampleQuality == original.currentSampleQuality)
    }

    @Test func groupingPrioritizesUsableSignalWithoutHidingPoorSamples() {
        let silent = assessed([Float](repeating: 0, count: 32000))
        let unassessed = example()
        let groups = VoiceIdentificationSelection.groups([silent, unassessed])
        #expect(groups.count == 2)
        #expect(groups.first?.representativeID == unassessed.id)
        #expect(groups.flatMap(\.examples).contains { $0.id == silent.id })

        var sameGroup = unassessed
        sameGroup.groupID = silent.groupID
        sameGroup.manuallyGrouped = true
        var groupedSilent = silent
        groupedSilent.manuallyGrouped = true
        #expect(
            VoiceIdentificationSelection.groups([groupedSilent, sameGroup]).first?.representativeID == sameGroup.id)
    }

    @MainActor @Test func qualityRefreshPreservesHumanDecisionAndRejectsDifferentRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let original = example()
        #expect(library.upsert([original]))
        let person = UUID()
        #expect(library.confirm(ids: [original.id], personID: person))
        var refreshed = original
        refreshed.sampleQuality = VoiceSampleQuality.assess(
            range: original.range!, audioRevision: original.audioRevision!, scanConfiguration: "synthetic-scan-v1",
            samples: [Float](repeating: 0, count: 32000))
        #expect(library.upsert([refreshed]))
        let stored = try #require(library.examples.first)
        #expect(stored.personID == person)
        #expect(stored.review == .confirmed)
        #expect(stored.currentSampleQuality?.issue == .nearSilentAudio)
        refreshed.audioRevision = "different-revision"
        refreshed.sampleQuality?.audioRevision = "different-revision"
        refreshed.sampleQuality?.nearSilentFraction = 0
        #expect(library.upsert([refreshed]))
        #expect(library.examples.first?.currentSampleQuality?.issue == .nearSilentAudio)
    }

    @Test func cacheQualityRefreshReusesScanRangesAndSkipsCurrentPCM() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("system.wav")
        try Data("synthetic source revision".utf8).write(to: audio)
        let revision = try #require(VoiceLibraryStore.revision(url: audio))
        var speaker = MeetingSpeaker(label: "voice_a", track: "track0", providerName: "Synthetic")
        speaker.voiceSampleRange = example().range
        speaker.voiceSampleRevision = revision
        let input = VoiceDiscoveryInput(
            meetingID: UUID(), audioFiles: ["system.wav"], audioRevisions: ["system.wav": revision])
        let result = LocalDiarizationResult(modelRevision: "synthetic-model", ranges: [], speakers: [speaker])
        let config = VoiceDiscoveryConfiguration(model: "synthetic", revision: "v1", pipeline: "synthetic-scan")
        let refreshed = try await VoiceSampleQuality.refresh(
            result: result, input: input, configuration: config, directory: directory,
            readSamples: { _, _ in [Float](repeating: 0, count: 32000) })
        let key = VoiceSampleQuality.speakerKey(track: speaker.track, label: speaker.label)
        #expect(refreshed.sampleQualities?[key]?.issue == .nearSilentAudio)
        #expect(refreshed.modelRevision == result.modelRevision)
        #expect(refreshed.ranges == result.ranges)
        let unchanged = try await VoiceSampleQuality.refresh(
            result: refreshed, input: input, configuration: config, directory: directory,
            readSamples: { _, _ in throw ServiceError("Current cached PCM must be reused.") })
        #expect(unchanged.sampleQualities == refreshed.sampleQualities)
        var stale = refreshed
        stale.sampleQualities?[key]?.policy = "old-policy"
        let policyRefresh = try await VoiceSampleQuality.refresh(
            result: stale, input: input, configuration: config, directory: directory,
            readSamples: { _, _ in [Float](repeating: 0.25, count: 32000) })
        #expect(policyRefresh.sampleQualities?[key]?.policy == VoiceSampleQuality.policyVersion)
        #expect(policyRefresh.sampleQualities?[key]?.issue == nil)
        #expect(!VoiceDiscoveryConfiguration.community.pipeline.contains(VoiceSampleQuality.policyVersion))
        let unavailable = try await VoiceSampleQuality.refresh(
            result: stale, input: input, configuration: config, directory: directory,
            readSamples: { _, _ in throw ServiceError("Synthetic audio decoding failure.") })
        #expect(unavailable.sampleQualities?[key] == nil)
        #expect(unavailable.speakers == stale.speakers)
        await #expect(throws: ServiceError.self) {
            try await VoiceSampleQuality.refresh(
                result: stale, input: input, configuration: config, directory: directory,
                readSamples: { url, _ in
                    try Data("different synthetic source revision and byte count".utf8).write(to: url)
                    return [Float](repeating: 0, count: 32000)
                })
        }
    }

    @Test func duplicateOwnershipPrecedesQualityAndCoverageSorting() {
        var first = assessed([Float](repeating: 0, count: 32000))
        first.groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        first.suggestedPersonID = UUID()
        var alias = first
        alias.id = UUID()
        alias.groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        alias.sampleQuality = nil
        var extra = example()
        extra.groupID = alias.groupID
        extra.suggestedPersonID = first.suggestedPersonID
        let initial = VoiceIdentificationSelection.groups([alias, first])
        #expect(initial.first?.id == first.groupID)
        let expanded = VoiceIdentificationSelection.groups([alias, first, extra])
        #expect(expanded.first { $0.id == first.groupID }?.examples.map(\.id) == [first.id])
        #expect(expanded.first { $0.id == alias.groupID }?.examples.map(\.id) == [extra.id])
    }
}
