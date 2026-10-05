import Foundation
import Testing

@testable import GdayMeetings

struct LocalVoiceSearchTests {
    private actor Worker: VoiceEmbeddingWorker {
        private(set) var audioRanges: [(Double, Double)] = []
        private(set) var textCalls = 0
        var delay: Duration = .zero
        func shutdown() {}
        func setDelay(_ value: Duration) { delay = value }
        func embed(texts: [String]) async throws -> LocalSearchEmbeddingResponse {
            textCalls += 1
            return response()
        }
        func embed(audio: URL, start: Double, duration: Double) async throws -> LocalSearchEmbeddingResponse {
            try await Task.sleep(for: delay)
            audioRanges.append((start, duration))
            return response()
        }
        private func response() -> LocalSearchEmbeddingResponse {
            let space = VoiceEmbeddingSpace.clsp
            return .init(
                model: space.model, revision: space.revision, preprocessing: space.preprocessing,
                dimension: space.dimension, normalization: space.normalization,
                vectors: [LocalVoiceSearchTests.vector(0)])
        }
    }
    private static func vector(_ position: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: 512)
        result[position] = 1
        return result
    }
    private func fixture() throws -> (URL, Meeting, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-search-\(UUID())")
        var meeting = Meeting(title: "Synthetic audio search")
        meeting.audioFiles = ["synthetic.wav"]
        try MeetingFolderStorage.write(meeting, directory: root)
        let audio = MeetingFolderStorage.folder(id: meeting.id, directory: root).appendingPathComponent("synthetic.wav")
        // The worker and duration reader are injected; no real audio or model is used.
        try Data("Synthetic audio source bytes.".utf8).write(to: audio)
        try LibraryIndex(directory: root).rebuild()
        return (root, meeting, audio)
    }
    private func artifact(meeting: Meeting, audio: URL, start: Double, vector: [Double]) throws -> VoiceSearchArtifact {
        .init(
            meetingID: meeting.id, audioFilename: audio.lastPathComponent,
            sourceRevision: try VoiceSearchArtifacts.sourceRevision(audio).0, start: start, duration: 15,
            space: .clsp, vector: vector)
    }
    private func results(
        _ index: LocalVoiceSearchIndex, after: Int64 = 0, limit: Int = 50,
        excluding: Set<UUID> = []
    ) throws -> ([ProviderSearchResult], Int) {
        var results: [ProviderSearchResult] = []
        var total = 0
        try index.search(
            vector: Self.vector(0),
            request: .init(
                query: "Synthetic voice", mode: .voice,
                limit: limit, after: after, excludingTagIDs: excluding)
        ) { rows, count, final in
            if final {
                results = rows
                total = count
            }
        }
        return (results, total)
    }

    @Test func explicitBuildChunksAudioAndDoesNotStartWorkerDuringInitialization() async throws {
        let (root, meeting, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Worker()
        let provider = try LocalVoiceSearchProvider(
            directory: root, indexDirectory: root, worker: worker,
            audioDuration: { _ in 65 })
        #expect(await worker.audioRanges.isEmpty)
        #expect(await worker.textCalls == 0)
        #expect(try await provider.build(meetingID: meeting.id) == 3)
        let ranges = await worker.audioRanges
        #expect(ranges.map(\.0) == [0, 30, 60])
        #expect(ranges.map(\.1) == [30, 30, 5])
        #expect(try await provider.build(meetingID: meeting.id) == 3)
        #expect(await worker.audioRanges.count == 3)
        var files: [URL] = []
        try provider.index.artifacts.enumerate { files.append($0) }
        #expect(files.count == 3)
        var final: ProviderSearchSnapshot?
        for try await event in provider.search(.init(query: "A synthetic description", mode: .voice)) {
            if event.value.isFinal { final = event.value }
        }
        #expect(final?.results.count == 1)
        #expect(final?.results.allSatisfy { $0.audio?.filename == "synthetic.wav" && $0.passage == nil } == true)
        #expect(await worker.textCalls == 1)

        // Folder labels can change without changing a meeting's identity.
        let original = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let renamed = original.deletingLastPathComponent().appendingPathComponent(
            "20000101_" + MeetingIdentity.string(meeting.id))
        try FileManager.default.moveItem(at: original, to: renamed)
        MeetingFolderLocation.remember(renamed, id: meeting.id, directory: provider.index.artifacts.directory)
        #expect(try await provider.build(meetingID: meeting.id) == 3)
        #expect(await worker.audioRanges.count == 3)
        #expect(try results(provider.index).1 == 1)
    }

    @Test func exactCosineOrdersPagesAndAppliesTagExclusionsBeforeRanking() throws {
        let (root, meeting, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LocalVoiceSearchIndex(directory: root, indexDirectory: root)
        let fingerprint = try VoiceSourceFingerprint.read(audio)
        let low = try artifact(meeting: meeting, audio: audio, start: 0, vector: Self.vector(1))
        let high = try artifact(meeting: meeting, audio: audio, start: 15, vector: Self.vector(0))
        try index.persist(low, fingerprint: fingerprint)
        try index.persist(high, fingerprint: fingerprint)
        var other = Meeting(title: "Another synthetic audio meeting")
        other.audioFiles = ["synthetic.wav"]
        try MeetingFolderStorage.write(other, directory: root)
        let otherAudio = MeetingFolderStorage.folder(id: other.id, directory: root).appendingPathComponent(
            "synthetic.wav")
        try Data("Another synthetic audio source.".utf8).write(to: otherAudio)
        try LibraryIndex(directory: root).upsert(MeetingListEntry(other))
        let otherClip = try artifact(meeting: other, audio: otherAudio, start: 0, vector: Self.vector(1))
        try index.persist(otherClip, fingerprint: VoiceSourceFingerprint.read(otherAudio))
        #expect(try results(index, limit: 1).0.first?.id == high.id)
        #expect(try results(index, after: 1, limit: 1).0.first?.id == otherClip.id)
        #expect(try results(index).1 == 2)
        let excluded = UUID()
        var tagged = meeting
        tagged.tagIDs = [excluded]
        try MeetingFolderStorage.write(tagged, directory: root)
        try LibraryIndex(directory: root).upsert(MeetingListEntry(tagged))
        #expect(try results(index, excluding: [excluded]).0.map(\.meetingID) == [other.id])
    }

    @Test func aShortTrailingRangeUsesAnOverlappingModelWindow() async throws {
        let (root, meeting, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Worker()
        let provider = try LocalVoiceSearchProvider(
            directory: root, indexDirectory: root, worker: worker,
            audioDuration: { _ in 30.1 })
        #expect(try await provider.build(meetingID: meeting.id) == 2)
        let ranges = await worker.audioRanges
        #expect(ranges.count == 2)
        #expect(ranges.allSatisfy { $0.1 >= 0.25 && $0.1 <= 30 })
        #expect(abs(ranges[1].0 + ranges[1].1 - 30.1) < 0.000_001)
        #expect(ranges[1].0 < ranges[0].0 + ranges[0].1)
    }

    @Test func sourceAndArtifactChangesHideStaleRowsUntilExplicitRebuild() throws {
        let (root, meeting, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LocalVoiceSearchIndex(directory: root, indexDirectory: root)
        let clip = try artifact(meeting: meeting, audio: audio, start: 0, vector: Self.vector(0))
        try index.persist(clip, fingerprint: VoiceSourceFingerprint.read(audio))
        #expect(try results(index).1 == 1)
        let file = index.artifacts.url(for: clip)
        try FileManager.default.removeItem(at: file)
        #expect(try results(index).1 == 0)
        #expect(try index.rebuild().indexedClips == 0)
        try index.persist(clip, fingerprint: VoiceSourceFingerprint.read(audio))
        try Data("Changed synthetic audio source.".utf8).write(to: audio)
        #expect(try results(index).1 == 0)
        let rebuilt = try index.rebuild()
        #expect(rebuilt.indexedClips == 0)
        #expect(rebuilt.rejectedArtifacts == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func rebuildingFromPortableArtifactsNeedsNoWorkerAndRemovalKeepsAudio() throws {
        let (root, meeting, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceSearchArtifacts(directory: root)
        let clip = try artifact(meeting: meeting, audio: audio, start: 0, vector: Self.vector(0))
        try store.save(clip)
        let index = try LocalVoiceSearchIndex(directory: root, indexDirectory: root)
        #expect(try results(index).1 == 0)
        #expect(try index.rebuild().indexedClips == 1)
        #expect(try results(index).0.first?.sourceRevision == clip.sourceRevision)
        try index.remove(meetingID: meeting.id)
        #expect(try results(index).1 == 0)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: clip).path))
    }

    @Test func rowsOnlyInvalidationPreservesArtifactsForMeetingRestore() throws {
        let (root, meeting, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LocalVoiceSearchIndex(directory: root, indexDirectory: root)
        let clip = try artifact(meeting: meeting, audio: audio, start: 0, vector: Self.vector(0))
        try index.persist(clip, fingerprint: VoiceSourceFingerprint.read(audio))
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        // Move the whole owned folder, as the app's Trash operation does.
        let retained = root.appendingPathComponent("synthetic-trash")
        try FileManager.default.moveItem(at: folder, to: retained)
        try LibraryIndex(directory: root).remove(id: meeting.id)
        try index.invalidate(meetingID: meeting.id)
        #expect(try results(index).1 == 0)
        try FileManager.default.moveItem(at: retained, to: folder)
        try LibraryIndex(directory: root).rebuild()
        #expect(FileManager.default.fileExists(atPath: index.artifacts.url(for: clip).path))
        #expect(try index.rebuild().indexedClips == 1)
        #expect(try results(index).1 == 1)
    }

    @Test func malformedModelSpaceAndEscapingAudioNamesAreRejected() throws {
        let (root, meeting, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try VoiceSearchArtifacts.sourceRevision(audio).0
        let wrong = VoiceSearchArtifact(
            meetingID: meeting.id, audioFilename: audio.lastPathComponent,
            sourceRevision: revision, start: 0, duration: 15,
            space: .init(
                model: "synthetic-wrong-space", revision: "1", preprocessing: "other", dimension: 512,
                normalization: "unitL2"), vector: Self.vector(0))
        #expect(throws: (any Error).self) { try VoiceSearchArtifacts(directory: root).save(wrong) }
        let escaping = VoiceSearchArtifact(
            meetingID: meeting.id, audioFilename: "../outside.wav",
            sourceRevision: revision, start: 0, duration: 15, space: .clsp, vector: Self.vector(0))
        #expect(throws: (any Error).self) { try escaping.validate() }
    }

    @Test func cancelledBuildDoesNotPublishUnfinishedWorkerOutput() async throws {
        let (root, meeting, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Worker()
        await worker.setDelay(.seconds(10))
        let provider = try LocalVoiceSearchProvider(
            directory: root, indexDirectory: root, worker: worker,
            audioDuration: { _ in 30 })
        let build = Task { try await provider.build(meetingID: meeting.id) }
        build.cancel()
        do {
            _ = try await build.value
            Issue.record("The cancelled build returned a result.")
        }
        catch is CancellationError {}
        #expect(try results(provider.index).1 == 0)
        var artifacts = 0
        try provider.index.artifacts.enumerate { _ in artifacts += 1 }
        #expect(artifacts == 0)
    }
}
