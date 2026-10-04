import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

private actor FakeVoiceExampleExtractor: VoiceExampleEmbeddingExtracting {
    var calls = 0
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
    init(result: LocalDiarizationResult) { self.result = result }
    func discover(files: [URL]) async throws -> LocalDiarizationResult {
        calls += 1
        lastFiles = files.map(\.lastPathComponent)
        return result
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

    @Test func providersShareRepresentationWithoutTrustingEndpointOrDimensions() {
        #expect(VoiceLibraryPreparation.capability(for: ServiceProvider(kind: .nemotron)).type == .community1)
        #expect(VoiceLibraryPreparation.capability(for: ServiceProvider(kind: .community1)).type == .community1)
        #expect(!VoiceLibraryPreparation.capability(for: ServiceProvider(kind: .runpod)).isAvailable)
        var disabled = ServiceProvider(kind: .community1)
        disabled.isEnabled = false
        #expect(!VoiceLibraryPreparation.capability(for: disabled).isAvailable)
    }

    @Test func reusesCompatibleEmbeddingWithoutReadingAudio() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
        var task = job([first, second])
        task.completedExampleIDs = [first.id]
        #expect(library.setJobs([task]))
        let reopened = VoiceLibraryStore(directory: directory)
        _ = VoiceLibraryPreparation(library: reopened, extractor: FakeVoiceExampleExtractor(result: embedding()))
        #expect(reopened.jobs.first?.state == .paused)
        #expect(reopened.jobs.first?.completedExampleIDs == [first.id])
    }

    @Test func excludedExamplesNeverReachExtractor() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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

    @Test func discoveryGroupsUnknownExamplesWithoutEnrollingThemOrUndoingSplits() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        let group = library.examples.first(where: { $0.id == first.id })?.groupID
        #expect(group == library.examples.first(where: { $0.id == second.id })?.groupID)
        #expect(group != library.examples.first(where: { $0.id == locked.id })?.groupID)
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
        #expect(library.jobs.first?.completedExampleIDs == [sample.id])
        #expect(library.hydratedExample(id: sample.id)?.voiceEmbeddings == [embedding()])
    }

    @Test func largeInventoryStartsAsDescriptorsAndCanPauseBeforeReadingAnyAudio() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
        let preparation = VoiceLibraryPreparation(
            library: library, extractor: FakeVoiceExampleExtractor(result: embedding()))
        let meetings = (0..<1000).map { _ in
            var meeting = Meeting()
            meeting.audioFiles = ["system.wav"]
            return meeting
        }
        let jobID = try #require(
            preparation.start(
                provider: ServiceProvider(kind: .community1), meetings: meetings,
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
}
