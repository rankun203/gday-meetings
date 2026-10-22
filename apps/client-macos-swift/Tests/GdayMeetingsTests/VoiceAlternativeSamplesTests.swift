import Foundation
import Testing

@testable import GdayMeetings

private actor AlternativeSampleExtractor: VoiceExampleEmbeddingExtracting {
    var calls = 0
    var onExtract: (@Sendable () async -> Void)?
    init(onExtract: (@Sendable () async -> Void)? = nil) { self.onExtract = onExtract }
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        calls += 1
        await onExtract?()
        return .init(type: type, values: [1] + Array(repeating: 0, count: type.dimension - 1))
    }
}

private actor AlternativeSampleGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseFirst() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct VoiceAlternativeSamplesTests {
    private func fixture() -> (VoiceExample, LocalDiarizationResult) {
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 0, end: 10)
        let example = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: range.audioFile,
            audioRevision: "synthetic", start: range.start, end: range.end, excluded: true)
        var speaker = MeetingSpeaker(label: "voice_a", track: "track0", providerName: "Synthetic Provider")
        speaker.voiceSampleRange = range
        let analysis = LocalDiarizationResult(
            modelRevision: "synthetic-v1",
            ranges: [
                .init(track: "track0", label: "voice_a", start: 0, end: 24),
                .init(track: "track0", label: "voice_b", start: 25, end: 35),
                .init(track: "track1", label: "voice_a", start: 40, end: 50),
            ], speakers: [speaker])
        return (example, analysis)
    }

    @Test func selectsUnusedSpeechFromSameSpeakerAndTrack() {
        let (original, analysis) = fixture()
        let next = VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original])
        #expect(next?.range?.start == 10)
        #expect(next?.range?.end == 20)
        #expect(original.excluded)
        var used = original
        used.id = UUID()
        used.start = 10
        used.end = 20
        let last = VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original, used])
        #expect(last?.range?.start == 20)
        #expect(last?.range?.end == 24)
        used.end = 24
        #expect(
            VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original, used])?.range
                == nil)
    }

    @Test func initialExtractionRoundingStillResolvesDetectedSpeaker() {
        let (original, initial) = fixture()
        var analysis = initial
        analysis.ranges[0].start = 0.00003
        let next = VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original])
        #expect(next?.range?.start == 10)
    }

    @Test func avoidsDetectedOverlapUnresolvedAndUncertainTurns() {
        let (original, initial) = fixture()
        var analysis = initial
        analysis.ranges.append(.init(track: "track0", label: "voice_b", start: 12, end: 20))
        analysis.unresolvedRanges = [.init(track: "track0", start: 20, end: 24)]
        let next = VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original])
        #expect(next?.range == nil)
        // A separate clean turn is preferred over fragments around uncertain boundaries.
        analysis.ranges.append(.init(track: "track0", label: "voice_a", start: 40, end: 44))
        #expect(
            VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original])?.range?.start
                == 40)
        analysis.ranges.removeLast()
        analysis.ranges[0].associationUncertain = true
        #expect(
            VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original])?.range == nil)
    }

    @Test func olderAnalysisAndAmbiguousSpeakerRemainUnavailable() {
        let (original, initial) = fixture()
        var analysis = initial
        analysis.ranges = []
        #expect(VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original]) == nil)
        analysis = initial
        var duplicate = analysis.speakers[0]
        duplicate.label = "voice_b"
        analysis.speakers.append(duplicate)
        analysis.ranges.append(.init(track: "track0", label: "voice_b", start: 0, end: 24))
        #expect(VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: [original]) == nil)
    }

    private func storedFixture() async throws -> (URL, URL, VoiceLibraryStore, VoiceExample) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alternative-samples-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (initial, analysis) = fixture()
        var original = initial
        let folder = try MeetingFolderLocation.newFolder(id: original.meetingID, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("Synthetic audio for injected extraction.".utf8).write(to: audio)
        original.audioRevision = VoiceLibraryStore.revision(url: audio)
        var meeting = Meeting()
        meeting.id = original.meetingID
        meeting.audioFiles = ["system.wav"]
        try MeetingFolderStorage.write(meeting, directory: root)
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert([original]))
        let input = VoiceDiscoveryInput(
            meetingID: original.meetingID, audioFiles: meeting.audioFiles,
            audioRevisions: ["system.wav": original.audioRevision!])
        try await VoiceDiscoveryCache().save(analysis, input: input, configuration: .community, directory: folder)
        return (root, folder, library, original)
    }

    @Test func preparesRepresentationBeforePublishingAndPreservesIgnoredDecision() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = AlternativeSampleExtractor()
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let undo = library.reviewUndoID
        let result = try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        guard case .prepared(let next) = result else {
            Issue.record("Expected another excerpt")
            return
        }
        #expect(next.start == 10)
        #expect(next.end == 20)
        #expect(next.embeddings.first?.type == CommunityVoiceEmbeddingExtractor.embeddingType)
        #expect(!next.excluded && next.personID == nil && next.rejectedPersonIDs.isEmpty)
        #expect(library.examples.first(where: { $0.id == original.id })?.excluded == true)
        #expect(library.reviewUndoID == undo)
        let second = try await preparation.tryAnotherSample(exampleID: next.id, directory: folder)
        guard case .prepared(let last) = second else {
            Issue.record("Expected remaining excerpt")
            return
        }
        #expect(last.start == 20 && last.end == 24)
        #expect(try await preparation.tryAnotherSample(exampleID: last.id, directory: folder) == .exhausted)
        #expect(await extractor.calls == 2)
    }

    @Test func discardsLateExtractionWhenOriginalDecisionChanges() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = AlternativeSampleExtractor(onExtract: {
            await MainActor.run { _ = library.exclude(ids: [original.id], excluded: false) }
        })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        await #expect(throws: (any Error).self) {
            try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        }
        #expect(library.examples.count == 1)
    }

    @Test func discardsLateExtractionWhenAudioRevisionChanges() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = AlternativeSampleExtractor(onExtract: {
            try? Data("Changed synthetic audio fixture.".utf8).write(to: folder.appendingPathComponent("system.wav"))
        })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        await #expect(throws: (any Error).self) {
            try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        }
        #expect(library.examples.count == 1)
    }
    @Test func cancelledPreparationPublishesNoSampleAndCanRetry() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.exclude(ids: [original.id]))
        let ignored = try #require(library.examples.first { $0.id == original.id })
        let undoBeforePreparation = library.reviewUndoID
        let cancelled = VoiceLibraryPreparation(
            library: library,
            extractor: AlternativeSampleExtractor(onExtract: { withUnsafeCurrentTask { $0?.cancel() } }))
        let task = Task { try await cancelled.tryAnotherSample(exampleID: original.id, directory: folder) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(library.examples.count == 1)
        #expect(library.examples.first?.hasSameReviewEvidence(as: ignored) == true)
        #expect(library.reviewUndoID == undoBeforePreparation)
        let retry = VoiceLibraryPreparation(library: library, extractor: AlternativeSampleExtractor())
        guard case .prepared = try await retry.tryAnotherSample(exampleID: original.id, directory: folder) else {
            Issue.record("Expected retry to prepare a sample")
            return
        }
        #expect(library.examples.count == 2)
        #expect(library.examples.first { $0.id == original.id }?.hasSameReviewEvidence(as: ignored) == true)
        #expect(library.reviewUndoID == undoBeforePreparation)
    }

    @Test func retainedAnalysisRoundTripsAndOldCacheRequiresRescan() async throws {
        let (root, folder, _, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = VoiceDiscoveryInput(
            meetingID: original.meetingID, audioFiles: ["system.wav"],
            audioRevisions: ["system.wav": original.audioRevision!])
        let cache = VoiceDiscoveryCache()
        let analysis = try await cache.read(input: input, configuration: .community, directory: folder)
        #expect(analysis?.ranges.count == 3)
        let paths = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent(VoiceDiscoveryCache.directoryName), includingPropertiesForKeys: nil)
        let path = try #require(paths.first)
        var entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        entry["version"] = 2
        entry.removeValue(forKey: "ranges")
        try JSONSerialization.data(withJSONObject: entry).write(to: path)
        #expect(try await cache.read(input: input, configuration: .community, directory: folder) == nil)
        try await cache.save(fixture().1, input: input, configuration: .community, directory: folder)
        #expect(try await cache.read(input: input, configuration: .community, directory: folder)?.ranges.count == 3)
    }

    @Test func newerAlternativeRequestSupersedesDelayedRequest() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AlternativeSampleGate()
        let extractor = AlternativeSampleExtractor(onExtract: { await gate.pauseFirst() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let older = Task { try await preparation.tryAnotherSample(exampleID: original.id, directory: folder) }
        while !(await gate.entered) { await Task.yield() }
        let newer = try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await older.value }
        guard case .prepared = newer else {
            Issue.record("Expected newer request to finish")
            return
        }
        #expect(library.examples.count == 2)
    }

    @Test func presentAnalysisWithUnresolvedSpeakerDoesNotRequestRepeatedScanning() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = VoiceDiscoveryInput(
            meetingID: original.meetingID, audioFiles: ["system.wav"],
            audioRevisions: ["system.wav": original.audioRevision!])
        var analysis = fixture().1
        analysis.ranges = []
        try await VoiceDiscoveryCache().save(analysis, input: input, configuration: .community, directory: folder)
        let extractor = AlternativeSampleExtractor()
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        #expect(try await preparation.tryAnotherSample(exampleID: original.id, directory: folder) == .speakerUnresolved)
        #expect(await extractor.calls == 0)
    }

    @Test func recordingSuspendsInFlightAlternativeAndAllowsRetryAfterCompletion() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AlternativeSampleGate()
        let extractor = AlternativeSampleExtractor(onExtract: { await gate.pauseFirst() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let pending = Task { try await preparation.tryAnotherSample(exampleID: original.id, directory: folder) }
        while !(await gate.entered) { await Task.yield() }
        #expect(preparation.pendingRunCount == 1)
        preparation.suspendForRecording()
        #expect(preparation.pendingRunCount == 1)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(preparation.pendingRunCount == 0)
        #expect(library.examples.count == 1)
        await #expect(throws: (any Error).self) {
            try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        }
        #expect(await extractor.calls == 1)
        preparation.resumeAfterRecording(directory: { _ in folder })
        guard case .prepared = try await preparation.tryAnotherSample(exampleID: original.id, directory: folder) else {
            Issue.record("Expected another sample after recording")
            return
        }
        #expect(library.examples.count == 2)
    }

    @Test func activeRecordingGuardRejectsPreparationBeforeSourceReadOrModelLoading() async throws {
        let (root, folder, library, original) = try await storedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = AlternativeSampleExtractor()
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: extractor, alternativePreparationAllowed: { false })
        await #expect(throws: (any Error).self) {
            try await preparation.tryAnotherSample(exampleID: original.id, directory: folder)
        }
        #expect(await extractor.calls == 0)
        #expect(library.examples.count == 1)
    }

}
