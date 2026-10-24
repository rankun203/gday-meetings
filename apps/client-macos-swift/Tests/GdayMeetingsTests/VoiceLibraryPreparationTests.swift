import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import GdayMeetings

private actor FakeVoiceExampleExtractor: VoiceExampleEmbeddingExtracting {
    var calls = 0
    var finishes = 0
    func finish() async { finishes += 1 }
    var failuresRemaining: Int
    let result: TypedVoiceEmbedding
    let onExtract: (@Sendable () async -> Void)?
    init(result: TypedVoiceEmbedding, failures: Int = 0, onExtract: (@Sendable () async -> Void)? = nil) {
        self.result = result
        failuresRemaining = failures
        self.onExtract = onExtract
    }
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        calls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ServiceError("Synthetic extraction failure.")
        }
        await onExtract?()
        return result
    }
}

private actor FakeVoiceRecordingDiscoverer: VoiceRecordingDiscovering {
    var calls = 0
    var lastFiles: [String] = []
    let result: LocalDiarizationResult
    let identity: VoiceDiscoveryConfiguration
    let onDiscover: (@Sendable () async -> Void)?
    init(
        result: LocalDiarizationResult, configuration: VoiceDiscoveryConfiguration = .community,
        onDiscover: (@Sendable () async -> Void)? = nil
    ) {
        self.result = result
        self.identity = configuration
        self.onDiscover = onDiscover
    }
    func configuration() async -> VoiceDiscoveryConfiguration { identity }
    func discover(files: [URL]) async throws -> LocalDiarizationResult {
        calls += 1
        lastFiles = files.map(\.lastPathComponent)
        await onDiscover?()
        return result
    }
}

private actor VoiceRetirementGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class VoicePreparationJobWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func wrote(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "jobs" else { return }
        lock.lock()
        value += 1
        lock.unlock()
    }
    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor VoiceSecondExtractionGate {
    var calls = 0
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func visit() async {
        calls += 1
        guard calls == 2 else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct VoiceLibraryPreparationTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("voice-preparation-tests-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func embedding(type: EmbeddingType = .community1) -> TypedVoiceEmbedding {
        .init(type: type, values: [1] + Array(repeating: 0, count: type.dimension - 1))
    }
    private func example(in directory: URL, embeddings: [TypedVoiceEmbedding] = []) throws -> VoiceExample {
        let meetingID = UUID()
        let folder = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("Synthetic audio fixture for the fake extractor.".utf8).write(to: audio)
        var meeting = Meeting()
        meeting.id = meetingID
        meeting.audioFiles = ["system.wav"]
        try MeetingFolderStorage.write(meeting, directory: directory)
        return .init(
            meetingID: meetingID, speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: audio), start: 0, end: 3,
            review: .confirmed, embeddings: embeddings)
    }
    private func job(_ examples: [VoiceExample], discover: Bool = false) -> VoicePreparationJob {
        .init(
            providerID: UUID(), providerName: "Synthetic Provider", type: .community1, discover: discover,
            exampleIDs: examples.map(\.id), state: .running)
    }

    @Test func aJobReusesItsSessionAcrossExamplesAndFinishesAfterFailure() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let samples = try (0..<3).map { _ in try example(in: directory) }
        #expect(library.upsert(samples))
        let extractor = FakeVoiceExampleExtractor(result: embedding(), failures: 1)
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job(samples)
        #expect(library.setJobs([task]))
        await preparation.run(
            jobID: task.id,
            directory: { id in
                try! MeetingFolderLocation.resolve(id: id, directory: directory)
            })
        #expect(await extractor.calls == 3)
        #expect(await extractor.finishes == 1)
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.completedExampleIDs.count == 2)
    }

    @Test func cachedAnalysisCompletesWithBatchCheckpointsWithoutInference() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = VoicePreparationJobWriteCounter()
        let library = VoiceLibraryStore(
            loading: .immediate, directory: directory,
            write: { data, url in
                try data.write(to: url, options: .atomic)
                counter.wrote(url)
            })
        let original = try example(in: directory, embeddings: [embedding()])
        let samples = (0..<512).map { index -> VoiceExample in
            var sample = original
            sample.id = UUID()
            sample.start = Double(index) * 4
            sample.end = Double(index) * 4 + 3
            return sample
        }
        #expect(library.upsert(samples))
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job(samples)
        #expect(library.setJobs([task]))
        counter.reset()
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 0)
        #expect(library.jobs.first?.completedExampleIDs.count == 512)
        #expect(library.jobs.first?.state == .completed)
        print("SYNTHETIC_ANALYSIS_CHECKPOINTS examples=512 jobWrites=\(counter.count)")
        #expect(counter.count < 32)
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.jobs.first?.completedExampleIDs.count == 512)
    }

    @Test func exactAudioAliasReusesCompatibleRepresentationWithoutCopyingReview() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var reference = try example(in: directory, embeddings: [embedding()])
        reference.personID = UUID()
        var alias = reference
        alias.id = UUID()
        alias.personID = nil
        alias.review = .unassigned
        alias.embeddings = []
        #expect(library.upsert([reference, alias]))
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([alias])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 0)
        #expect(library.hydratedExample(id: alias.id)?.embeddings == [embedding()])
        #expect(library.examples.first(where: { $0.id == alias.id })?.review == .unassigned)
        #expect(library.examples.first(where: { $0.id == alias.id })?.personID == nil)
        #expect(library.examples.first(where: { $0.id == reference.id })?.personID == reference.personID)
    }

    @Test func twoMissingExactAliasesNeedOneExtractionAndDifferentTypesRemainIndependent() async throws {
        for compatible in [true, false] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = VoiceLibraryStore(loading: .immediate, directory: directory)
            var first = try example(in: directory)
            if !compatible {
                var different = EmbeddingType.community1
                different.revision = "different-contract"
                first.embeddings = [embedding(type: different)]
            }
            var alias = first
            alias.id = UUID()
            alias.embeddings = []
            #expect(library.upsert([first, alias]))
            let extractor = FakeVoiceExampleExtractor(result: embedding())
            let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
            let task = job([first, alias])
            #expect(library.setJobs([task]))
            await preparation.run(jobID: task.id, directory: { _ in directory })
            #expect(await extractor.calls == 1)
            #expect(library.jobs.first?.completedExampleIDs.count == 2)
            #expect(library.hydratedExample(id: alias.id)?.embeddings == [embedding()])
            if !compatible {
                #expect(library.hydratedExample(id: first.id)?.embeddings.count == 2)
            }
        }
    }

    @Test func currentUnusableScanAssessmentCompletesWithoutRepeatingExtraction() async throws {
        for currentQuality in [true, false] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = VoiceLibraryStore(loading: .immediate, directory: directory)
            var sample = try example(in: directory)
            sample.detectedSpeakerConfiguration = .community
            sample.sampleQuality = .init(
                policy: VoiceSampleQuality.policyVersion, range: try #require(sample.range),
                audioRevision: currentQuality ? try #require(sample.audioRevision) : "obsolete-revision",
                scanConfiguration: VoiceDiscoveryConfiguration.community.pipeline,
                sampleCount: 48_000, nearSilentFraction: 1, fullScaleFraction: 0)
            #expect(library.upsert([sample]))
            let extractor = FakeVoiceExampleExtractor(result: embedding())
            let discovery = FakeVoiceRecordingDiscoverer(
                result: .init(modelRevision: "fixture", ranges: [], speakers: []))
            let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, discoverer: discovery)
            var task = job([sample], discover: true)
            task.discoveryConfiguration = .community
            #expect(library.setJobs([task]))
            await preparation.run(jobID: task.id, directory: { _ in directory })
            #expect(await extractor.calls == (currentQuality ? 0 : 1))
            #expect(library.jobs.first?.state == .completed)
            #expect(library.jobs.first?.completedExampleIDs == [sample.id])
        }
    }

    @Test func batchCheckpointRevalidatesAudioAfterAnotherExtractionSuspends() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let cached = try example(in: directory, embeddings: [embedding()])
        let missing = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: cached.meetingID, directory: directory)
        let audio = folder.appendingPathComponent("system.wav")
        #expect(library.upsert([cached, missing]))
        let extractor = FakeVoiceExampleExtractor(
            result: embedding(),
            onExtract: {
                try? Data("Replacement source during the next extraction.".utf8).write(to: audio, options: .atomic)
            })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([cached, missing])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 1)
        #expect(library.jobs.first?.completedExampleIDs == [missing.id])
        #expect(library.jobs.first?.failures[cached.id.uuidString] != nil)
        #expect(library.jobs.first?.state == .failed)
    }

    @Test func pausedBatchReusesPersistedVectorBeforeItsJobCheckpoint() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(in: directory)
        let second = try example(in: directory)
        #expect(library.upsert([first, second]))
        let gate = VoiceSecondExtractionGate()
        let extractor = FakeVoiceExampleExtractor(result: embedding(), onExtract: { await gate.visit() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([first, second])
        #expect(library.setJobs([task]))
        preparation.resume(jobID: task.id, directory: { _ in directory })
        while !(await gate.entered) { await Task.yield() }
        preparation.pause(jobID: task.id)
        await gate.open()
        while preparation.pendingRunCount > 0 { await Task.yield() }
        #expect(library.hydratedExample(id: first.id)?.embeddings == [embedding()])
        preparation.resume(jobID: task.id, directory: { _ in directory })
        while preparation.pendingRunCount > 0 { await Task.yield() }
        #expect(await extractor.calls == 3)
        #expect(library.jobs.first?.state == .completed)
        #expect(Set(library.jobs.first?.completedExampleIDs ?? []) == [first.id, second.id])
    }

    @Test func providersShareRepresentationWithoutTrustingEndpointOrDimensions() {
        #expect(
            VoiceLibraryPreparation.capability(for: ServiceProvider(kind: .speakerLabeling)).type
                == .community1SpeechSpan)
        #expect(!VoiceLibraryPreparation.capability(for: ServiceProvider(kind: .runpod)).isAvailable)
        var disabled = ServiceProvider(kind: .speakerLabeling)
        disabled.isEnabled = false
        #expect(!VoiceLibraryPreparation.capability(for: disabled).isAvailable)
    }

    @Test func reusesCompatibleEmbeddingWithoutReadingAudio() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var sample = try example(in: directory, embeddings: [embedding()])
        sample.audioFile = nil
        sample.audioRevision = nil
        sample.start = nil
        sample.end = nil
        #expect(library.upsert([sample]))
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([sample])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 0)
        #expect(library.jobs.first?.state == .completed)
        #expect(library.jobs.first?.completedExampleIDs == [sample.id])
    }

    @Test func failedItemsResumeWithoutRepeatingCompletedExamples() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(in: directory, embeddings: [embedding()])
        let second = try example(in: directory)
        #expect(library.upsert([first, second]))
        let extractor = FakeVoiceExampleExtractor(result: embedding(), failures: 1)
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([first, second])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.completedExampleIDs == [first.id])
        var retry = try #require(library.jobs.first)
        retry.state = .running
        #expect(library.setJobs([retry]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 2)
        #expect(library.jobs.first?.state == .completed)
        #expect(library.jobs.first?.failures.isEmpty == true)
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        #expect(library.hydratedExample(id: second.id)?.embeddings == [embedding()])
    }

    @Test func incompatibleOutputNeverBecomesAnExampleRepresentation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(in: directory)
        #expect(library.upsert([sample]))
        var incompatible = EmbeddingType.community1
        incompatible.revision = "synthetic-other-revision"
        let extractor = FakeVoiceExampleExtractor(result: embedding(type: incompatible))
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([sample])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(library.jobs.first?.state == .failed)
        #expect(library.hydratedExample(id: sample.id)?.embeddings.isEmpty == true)
    }

    @Test func reopeningPausesUnfinishedWorkAndRetainsProgress() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try example(in: directory)
        let second = try example(in: directory)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var task = job([first, second])
        task.completedExampleIDs = [first.id]
        #expect(library.setJobs([task]))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        _ = VoiceLibraryPreparation(library: reopened, extractor: FakeVoiceExampleExtractor(result: embedding()))
        #expect(reopened.jobs.first?.state == .paused)
        #expect(reopened.jobs.first?.completedExampleIDs == [first.id])
    }

    @Test func excludedExamplesNeverReachExtractor() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var sample = try example(in: directory)
        sample.excluded = true
        #expect(library.upsert([sample]))
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([sample])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(await extractor.calls == 0)
        #expect(library.jobs.first?.state == .completed)
    }

    @Test func discoveryPreparesGroupingEvidenceWithoutRewritingGroupsOrUndoingSplits() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var first = try example(in: directory, embeddings: [embedding()])
        var second = try example(in: directory, embeddings: [embedding()])
        var locked = try example(in: directory, embeddings: [embedding()])
        first.review = .unassigned
        second.review = .unassigned
        locked.review = .unassigned
        locked.manuallyGrouped = true
        #expect(library.upsert([first, second, locked]))
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()))
        let task = job([first, second, locked], discover: true)
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in directory })
        #expect(library.examples.first(where: { $0.id == first.id })?.groupID == first.groupID)
        #expect(library.examples.first(where: { $0.id == second.id })?.groupID == second.groupID)
        let groups = try await library.identificationGroups()
        #expect(groups.contains { Set($0.examples.map(\.id)) == [first.id, second.id] })
        #expect(groups.contains { $0.examples.map(\.id) == [locked.id] })
        #expect(library.examples.allSatisfy { $0.review == .unassigned && $0.personID == nil })
    }

    @Test func excerptReaderBoundsAndConvertsSyntheticAudio() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 15))
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) {
                let value = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.2)
                buffer.floatChannelData![0][index] = value
                buffer.floatChannelData![1][index] = value
            }
            try file.write(from: buffer)
        }
        let samples = try LocalVoiceExampleExtractor.readSamples(url: url, start: 1, end: 14)
        #expect(samples.count == 160000)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(throws: (any Error).self) {
            try LocalVoiceExampleExtractor.readSamples(url: url, start: 14, end: 18)
        }
    }

    @Test func earlierPreparationRejectsNewExtractionContractWithoutRetaggingSavedVectors() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = embedding(type: .community1)
        let sample = try example(in: directory, embeddings: [old])
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let range = try #require(sample.range)
        var speaker = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic")
        speaker.voiceSampleRange = range
        speaker.voiceEmbedding = embedding(type: .community1SpeechSpan)
        let discoverer = FakeVoiceRecordingDiscoverer(
            result: .init(
                modelRevision: "synthetic",
                ranges: [], speakers: [speaker]))
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let preparation = VoiceLibraryPreparation(
            library: library,
            extractor: FakeVoiceExampleExtractor(result: old), discoverer: discoverer)
        var task = job([], discover: true)
        task.discoveryInputs = [
            .init(
                meetingID: sample.meetingID, audioFiles: [range.audioFile],
                audioRevisions: [range.audioFile: try #require(sample.audioRevision)])
        ]
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.fullyAnalyzedRecordingIDs?.isEmpty != false)
        #expect(library.hydratedExample(id: sample.id)?.voiceEmbeddings == [old])
        #expect(library.examples.count == 1)
    }

    @Test func unlabeledDiscoveryIsResumableAndKeepsSavedTranscriptUntouched() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let transcript = folder.appendingPathComponent("transcript.jsonl")
        try TranscriptStorage.write([.init(start: 0, end: 3, speaker: "", text: "Synthetic speech.")], at: folder)
        let original = try Data(contentsOf: transcript)
        let range = try #require(sample.range)
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Synthetic Labeler")
        speaker.voiceSampleRange = range
        speaker.voiceEmbedding = embedding()
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic-revision", ranges: [], speakers: [speaker]))
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, discoverer: discovery)
        var task = job([], discover: true)
        task.discoveryInputs = [
            .init(
                meetingID: sample.meetingID, audioFiles: [range.audioFile],
                audioRevisions: [range.audioFile: try #require(sample.audioRevision)])
        ]
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(await extractor.calls == 0)
        #expect(library.jobs.first?.state == .completed)
        #expect(library.examples.count == 1)
        #expect(library.examples.first?.review == .unassigned)
        #expect(try Data(contentsOf: transcript) == original)
        let identity = library.examples.first?.id
        // Simulate a crash after persisting the result but before its completion checkpoint.
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(library.examples.count == 1)
        #expect(library.examples.first?.id == identity)
        #expect(try Data(contentsOf: transcript) == original)
    }

    @Test func changedRecordingBlocksNewAnalysisButRetainsCompatibleRepresentation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory, embeddings: [embedding()])
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: []))
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, discoverer: discovery)
        var task = job([sample], discover: true)
        task.discoveryInputs = [
            .init(
                meetingID: sample.meetingID, audioFiles: ["system.wav"],
                audioRevisions: ["system.wav": try #require(sample.audioRevision)])
        ]
        try Data("Replacement synthetic audio.".utf8).write(to: folder.appendingPathComponent("system.wav"))
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 0)
        #expect(await extractor.calls == 0)
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.completedExampleIDs.isEmpty == true)
        #expect(library.hydratedExample(id: sample.id)?.voiceEmbeddings == [embedding()])
    }

    @Test func cancelledReplacementRunsRetireAfterTheOldSessionFinishes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let gate = VoiceRetirementGate()
        let extractor = FakeVoiceExampleExtractor(result: embedding(), onExtract: { await gate.wait() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([sample])
        #expect(library.setJobs([task]))
        preparation.resume(jobID: task.id, directory: { _ in folder })
        while !(await gate.entered) { await Task.yield() }
        preparation.pause(jobID: task.id)
        for index in 0..<4 {
            preparation.resume(jobID: task.id, directory: { _ in folder })
            await Task.yield()
            if index.isMultiple(of: 2) {
                preparation.pause(jobID: task.id)
            }
            else {
                preparation.cancel(jobID: task.id)
            }
        }
        #expect(preparation.pendingRunCount == 5)
        await gate.open()
        await preparation.shutdown()
        #expect(preparation.pendingRunCount == 0)
        #expect(await extractor.calls == 1)
        #expect(await extractor.finishes == 1)
    }

    @Test func largeInventoryStartsAsDescriptorsAndCanPauseBeforeReadingAnyAudio() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()))
        let meetings = (0..<1000).map { _ in
            var meeting = Meeting()
            meeting.audioFiles = ["system.wav"]
            return meeting
        }
        let jobID = try #require(
            preparation.start(
                provider: ServiceProvider(kind: .speakerLabeling), meetings: meetings,
                directory: { _ in directory }, discover: true))
        preparation.pause(jobID: jobID)
        #expect(library.examples.isEmpty)
        #expect(library.jobs.first?.discoveryInputs.count == 1000)
        #expect(library.jobs.first?.state == .paused)
        #expect(library.jobs.first?.completedRecordingIDs.isEmpty == true)
    }

    @Test func audioReplacementDuringExtractionCannotCommitTheResult() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let audio = folder.appendingPathComponent("system.wav")
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let extractor = FakeVoiceExampleExtractor(
            result: embedding(),
            onExtract: {
                try? Data("Replacement synthetic audio during processing.".utf8).write(to: audio, options: .atomic)
            })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor)
        let task = job([sample])
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.completedExampleIDs.isEmpty == true)
        #expect(library.hydratedExample(id: sample.id)?.embeddings.isEmpty == true)
    }

    @Test func oneReviewedSourceDoesNotHideOtherVoicesAndFullAnalysisIsReused() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var microphone = try example(in: directory, embeddings: [embedding()])
        let folder = try MeetingFolderLocation.resolve(id: microphone.meetingID, directory: directory)
        let micFile = folder.appendingPathComponent("microphone.wav")
        try Data("Synthetic microphone source.".utf8).write(to: micFile)
        microphone.audioFile = "microphone.wav"
        microphone.audioRevision = VoiceLibraryStore.revision(url: micFile)
        microphone.source = "microphone"
        microphone.review = .rejected
        microphone.rejectedPersonIDs = [UUID()]
        var savedSpeaker = MeetingSpeaker(
            id: microphone.speakerID, label: "mic_01", track: "microphone", providerName: "Synthetic")
        savedSpeaker.voiceSampleRange = microphone.range
        var meeting = try MeetingFolderStorage.read(id: microphone.meetingID, directory: directory)
        meeting.audioFiles = ["microphone.wav", "system.wav"]
        meeting.speakers = [savedSpeaker]
        try MeetingFolderStorage.write(meeting, directory: directory)
        var discoveredSpeaker = MeetingSpeaker(label: "sys_01", track: "track1", providerName: "Synthetic")
        discoveredSpeaker.voiceSampleRange = .init(audioFile: "system.wav", source: "system", start: 0, end: 3)
        discoveredSpeaker.voiceEmbedding = embedding()
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic-revision", ranges: [], speakers: [discoveredSpeaker]))
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([microphone]))
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([microphone], discover: true)
        task.discoveryInputs = [
            .init(meetingID: microphone.meetingID, audioFiles: meeting.audioFiles, audioRevisions: [:])
        ]
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(await discovery.lastFiles == ["microphone.wav", "system.wav"])
        #expect(library.examples.contains { $0.audioFile == "system.wav" && $0.review == .unassigned })
        #expect(
            library.examples.first(where: { $0.id == microphone.id })?.rejectedPersonIDs == microphone.rejectedPersonIDs
        )
        let completed = try #require(library.jobs.first)
        #expect(completed.fullyAnalyzedRecordingIDs == [microphone.meetingID])
        meeting.speakers = []
        try MeetingFolderStorage.write(meeting, directory: directory)
        var next = task
        next.id = UUID()
        #expect(library.setJobs([completed, next]))
        await preparation.run(jobID: next.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(library.jobs.last?.state == .completed)
    }
    @Test func durableAnalysisSurvivesHistoryRemovalAndReopenAndReusesEmbeddings() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Synthetic")
        speaker.voiceSampleRange = sample.range
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: [speaker]))
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        var task = job([], discover: true)
        task.discoveryInputs = [.init(meetingID: sample.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, discoverer: discovery)
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(await extractor.calls == 1)
        #expect(library.jobs.first?.state == .completed)
        preparation.discard(jobID: task.id)
        #expect(library.jobs.isEmpty)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        task.id = UUID()
        #expect(reopened.setJobs([task]))
        let next = VoiceLibraryPreparation(library: reopened, extractor: extractor, discoverer: discovery)
        var resumed = try #require(reopened.jobs.first)
        resumed.state = .running
        #expect(reopened.setJobs([resumed]))
        await next.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(await extractor.calls == 1)
        #expect(reopened.jobs.first?.state == .completed)
    }

    @Test func discoveryCacheInvalidatesAudioModelAndConfigurationButRetainsOtherTiers() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Synthetic")
        speaker.voiceSampleRange = sample.range
        let result = LocalDiarizationResult(modelRevision: "synthetic", ranges: [], speakers: [speaker])
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let extractor = FakeVoiceExampleExtractor(result: embedding())
        let discovery = FakeVoiceRecordingDiscoverer(result: result)
        var task = job([], discover: true)
        task.discoveryInputs = [.init(meetingID: sample.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        func run(
            _ worker: FakeVoiceRecordingDiscoverer, using extractor: FakeVoiceExampleExtractor,
            type: EmbeddingType = .community1
        ) async {
            task.id = UUID()
            task.type = type
            #expect(library.setJobs([task]))
            let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, discoverer: worker)
            var running = library.jobs[0]
            running.state = .running
            #expect(library.setJobs([running]))
            await preparation.run(jobID: task.id, directory: { _ in folder })
        }
        await run(discovery, using: extractor)
        let originalIDs = Set(library.examples.map(\.id))
        let confirmedID = try #require(originalIDs.first)
        let personID = UUID()
        #expect(library.confirm(ids: [confirmedID], personID: personID))
        var changedType = EmbeddingType.community1SpeechSpan
        changedType.modelID = "synthetic-review-embedding-model"
        let changedExtractor = FakeVoiceExampleExtractor(result: embedding(type: changedType))
        await run(discovery, using: changedExtractor, type: changedType)
        #expect(await discovery.calls == 1)
        #expect(await changedExtractor.calls == 1)
        #expect(Set(library.examples.map(\.id)) == originalIDs)
        #expect(library.examples.first(where: { $0.id == confirmedID })?.personID == personID)
        #expect(library.examples.first(where: { $0.id == confirmedID })?.review == .confirmed)
        #expect(
            library.hydratedExample(id: confirmedID)?.voiceEmbeddings.contains(where: { $0.type == changedType })
                == true)
        var model = VoiceDiscoveryConfiguration.community
        model.revision += "-changed"
        let changedModel = FakeVoiceRecordingDiscoverer(result: result, configuration: model)
        await run(changedModel, using: extractor)
        #expect(await changedModel.calls == 1)
        #expect(await extractor.calls == 1)
        model.pipeline += "-changed"
        let changedConfig = FakeVoiceRecordingDiscoverer(result: result, configuration: model)
        await run(changedConfig, using: extractor)
        #expect(await changedConfig.calls == 1)
        try Data("Changed synthetic source audio.".utf8).write(to: folder.appendingPathComponent("system.wav"))
        await run(discovery, using: extractor)
        #expect(await discovery.calls == 2)
        #expect(await extractor.calls == 2)
    }

    @Test func savedLabelsArePartialEvidenceAndNeverSkipFullAnalysis() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory, embeddings: [embedding()])
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var meeting = try MeetingFolderStorage.read(id: sample.meetingID, directory: directory)
        var speaker = MeetingSpeaker(id: sample.speakerID, label: "sys_01", track: "system", providerName: "Synthetic")
        speaker.voiceSampleRange = sample.range
        speaker.voiceEmbedding = embedding()
        meeting.speakers = [speaker]
        try MeetingFolderStorage.write(meeting, directory: directory)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: []))
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([sample], discover: true)
        task.completedRecordingIDs = [sample.meetingID]
        task.fullyAnalyzedRecordingIDs = [sample.meetingID]
        task.discoveryInputs = [.init(meetingID: sample.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        #expect(library.setJobs([task]))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(library.examples.first(where: { $0.id == sample.id })?.review == .confirmed)
    }

    @Test func cancellationCannotSaveAnAnalysisReceiptOrPublishExamples() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Synthetic")
        speaker.voiceSampleRange = sample.range
        let gate = VoiceRetirementGate()
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: [speaker]),
            onDiscover: { await gate.wait() })
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([], discover: true)
        task.discoveryInputs = [.init(meetingID: sample.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        #expect(library.setJobs([task]))
        preparation.resume(jobID: task.id, directory: { _ in folder })
        while !(await gate.entered) { await Task.yield() }
        preparation.pause(jobID: task.id)
        await gate.open()
        await preparation.shutdown()
        #expect(library.examples.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("voice-analysis").path))
        #expect(library.jobs.first?.state == .paused)
    }

    @Test func resumeChecksCurrentExtractionContractAndSelectedProvider() {
        var provider = ServiceProvider(kind: .speakerLabeling)
        var task = job([])
        task.providerID = provider.id
        #expect(VoiceLibraryPreparation.resumeUnavailableReason(for: task, provider: provider) != nil)
        task.type = .community1SpeechSpan
        #expect(VoiceLibraryPreparation.resumeUnavailableReason(for: task, provider: provider) == nil)
        provider.id = UUID()
        #expect(VoiceLibraryPreparation.resumeUnavailableReason(for: task, provider: provider) != nil)
    }

    @Test func effectiveDiscoveryConfigurationTracksInferenceOptions() {
        let original = CommunityDiarizationWorker.discoveryConfiguration
        let baseline = VoiceDiscoveryConfiguration.fingerprint(original)
        #expect(baseline == VoiceDiscoveryConfiguration.fingerprint(original))
        var segmentation = original
        segmentation.segmentation.stepRatio = 0.4
        #expect(baseline != VoiceDiscoveryConfiguration.fingerprint(segmentation))
        var clustering = original
        clustering.clustering.threshold = 0.8
        #expect(baseline != VoiceDiscoveryConfiguration.fingerprint(clustering))
        var embedding = original
        embedding.embedding.skipStrategy = .maskSimilarity(threshold: 0.95)
        #expect(baseline != VoiceDiscoveryConfiguration.fingerprint(embedding))
    }

    @Test func analysisCacheRejectsAnExternalSymlinkWithoutWritingOutsideRecording() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = try self.directory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("voice-analysis"), withDestinationURL: outside)
        let input = VoiceDiscoveryInput(
            meetingID: UUID(), audioFiles: ["system.wav"], audioRevisions: ["system.wav": "synthetic"])
        let cache = VoiceDiscoveryCache()
        await #expect(throws: (any Error).self) {
            try await cache.save(
                .init(modelRevision: "synthetic", ranges: [], speakers: []), input: input,
                configuration: .community, directory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func engineReportsCompletedWithErrorsAfterOneRecordingFailsAndOneSucceeds() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try example(in: directory)
        let second = try example(in: directory)
        let failedFolder = try MeetingFolderLocation.resolve(id: second.meetingID, directory: directory)
        try FileManager.default.removeItem(at: failedFolder.appendingPathComponent("system.wav"))
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: []))
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([], discover: true)
        task.discoveryInputs = [first, second].map {
            .init(meetingID: $0.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])
        }
        #expect(library.setJobs([task]))
        await preparation.run(
            jobID: task.id, directory: { try! MeetingFolderLocation.resolve(id: $0, directory: directory) })
        let result = try #require(library.jobs.first)
        #expect(result.state == .failed)
        #expect(result.failures.count == 1)
        #expect(result.completedRecordingIDs == [first.meetingID])
        #expect(result.outcomeTitle == "Completed with Errors")
    }

    @Test func legacyReceiptRestartsAtZeroAndCurrentCheckpointSkipsReplayButChecksFreshness() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        let gate = VoiceRetirementGate()
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: []), onDiscover: { await gate.wait() })
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([], discover: true)
        task.completedRecordingIDs = [sample.meetingID]
        task.fullyAnalyzedRecordingIDs = [sample.meetingID]
        task.discoveryInputs = [.init(meetingID: sample.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        #expect(library.setJobs([task]))
        let run = Task { await preparation.run(jobID: task.id, directory: { _ in folder }) }
        while !(await gate.entered) { await Task.yield() }
        #expect(library.jobs.first?.completedRecordingIDs.isEmpty == true)
        #expect(library.jobs.first?.fullyAnalyzedRecordingIDs?.isEmpty == true)
        #expect(library.jobs.first?.progressDetails.completed == 0)
        await gate.open()
        await run.value
        var resumed = try #require(library.jobs.first)
        resumed.state = .running
        #expect(library.setJobs([resumed]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("voice-analysis"))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        resumed = try #require(library.jobs.first)
        resumed.state = .running
        #expect(library.setJobs([resumed]))
        try Data("Changed synthetic completed recording.".utf8).write(to: folder.appendingPathComponent("system.wav"))
        await preparation.run(jobID: task.id, directory: { _ in folder })
        #expect(await discovery.calls == 1)
        #expect(library.jobs.first?.state == .failed)
        #expect(library.jobs.first?.completedRecordingIDs.isEmpty == true)
        #expect(library.jobs.first?.outcomeTitle == "Failed")
    }

    @Test func automaticResumeAfterRecordingRechecksGeneralProvider() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var provider = ServiceProvider(kind: .speakerLabeling)
        let gate = VoiceRetirementGate()
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let extractor = FakeVoiceExampleExtractor(
            result: embedding(type: .community1SpeechSpan), onExtract: { await gate.wait() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, currentProvider: { provider })
        var task = job([sample])
        task.providerID = provider.id
        task.type = .community1SpeechSpan
        #expect(library.setJobs([task]))
        preparation.resume(jobID: task.id, directory: { _ in folder })
        while !(await gate.entered) { await Task.yield() }
        preparation.suspendForRecording()
        provider.id = UUID()
        preparation.resumeAfterRecording(directory: { _ in folder })
        #expect(library.jobs.first?.state == .paused)
        #expect(preparation.errorMessage?.contains("provider changed") == true)
        await gate.open()
        await preparation.shutdown()
        #expect(await extractor.calls == 1)
    }

    @Test func recordingCacheStoresRangesWithoutRepresentationsOrIdentityDecisions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var speaker = MeetingSpeaker(label: "sys_01", track: "track0", providerName: "Synthetic")
        speaker.voiceSampleRange = .init(audioFile: "system.wav", source: "system", start: 0, end: 3)
        speaker.voiceEmbedding = embedding()
        speaker.personID = UUID()
        let input = VoiceDiscoveryInput(
            meetingID: UUID(), audioFiles: ["system.wav"], audioRevisions: ["system.wav": "synthetic"])
        let cache = VoiceDiscoveryCache()
        try await cache.save(
            .init(modelRevision: "synthetic", ranges: [], speakers: [speaker]), input: input,
            configuration: .community, directory: directory)
        let cached = try #require(try await cache.read(input: input, configuration: .community, directory: directory))
        #expect(cached.speakers.count == 1)
        #expect(cached.speakers.first?.voiceEmbedding == nil)
        #expect(cached.speakers.first?.personID == nil)
        #expect(cached.speakers.first?.voiceSampleRange == speaker.voiceSampleRange)
    }

    @Test func discoveryCacheEngineIdentityMatchesPinnedFluidAudioRevision() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.resolved")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: package)) as? [String: Any])
        let pins = try #require(document["pins"] as? [[String: Any]])
        let fluid = try #require(pins.first { ($0["identity"] as? String)?.lowercased() == "fluidaudio" })
        let state = try #require(fluid["state"] as? [String: Any])
        let revision = try #require(state["revision"] as? String)
        #expect(VoiceDiscoveryConfiguration.community.pipeline.hasPrefix("FluidAudio-" + revision + "|"))
    }

    @Test func allRecordingFailuresRemainFailedWhenEarlierExamplesWerePrepared() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = try example(in: directory, embeddings: [embedding()])
        let failed = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: failed.meetingID, directory: directory)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([reference]))
        let discovery = FakeVoiceRecordingDiscoverer(
            result: .init(modelRevision: "synthetic", ranges: [], speakers: []))
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()), discoverer: discovery)
        var task = job([reference], discover: true)
        task.completedExampleIDs = [reference.id]
        task.discoveryInputs = [.init(meetingID: failed.meetingID, audioFiles: ["system.wav"], audioRevisions: [:])]
        #expect(library.setJobs([task]))
        await preparation.run(
            jobID: task.id, directory: { try! MeetingFolderLocation.resolve(id: $0, directory: directory) })
        let result = try #require(library.jobs.first)
        #expect(result.state == .failed)
        #expect(result.completedRecordingIDs.isEmpty)
        #expect(result.completedExampleIDs == [reference.id])
        #expect(result.outcomeTitle == "Failed")
        #expect(await discovery.calls == 0)
    }

    @Test func deferredResumePublishesProviderChangeAndClearsItAfterCorrection() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try example(in: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var provider = ServiceProvider(kind: .speakerLabeling)
        let initialProvider = provider
        let gate = VoiceRetirementGate()
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([sample]))
        let extractor = FakeVoiceExampleExtractor(
            result: embedding(type: .community1SpeechSpan), onExtract: { await gate.wait() })
        let preparation = VoiceLibraryPreparation(library: library, extractor: extractor, currentProvider: { provider })
        var task = job([sample])
        task.providerID = provider.id
        task.type = .community1SpeechSpan
        #expect(library.setJobs([task]))
        preparation.resume(jobID: task.id, directory: { _ in folder })
        while !(await gate.entered) { await Task.yield() }
        preparation.pause(jobID: task.id)
        preparation.resume(jobID: task.id, directory: { _ in folder })
        provider.id = UUID()
        await gate.open()
        while preparation.pendingRunCount > 0 { await Task.yield() }
        #expect(library.jobs.first?.state == .paused)
        #expect(library.jobs.first?.failures["configuration"]?.contains("provider changed") == true)
        #expect(await extractor.calls == 1)
        provider = initialProvider
        preparation.resume(jobID: task.id, directory: { _ in folder })
        #expect(library.jobs.first?.failures["configuration"] == nil)
        preparation.pause(jobID: task.id)
        await preparation.shutdown()
    }

}
