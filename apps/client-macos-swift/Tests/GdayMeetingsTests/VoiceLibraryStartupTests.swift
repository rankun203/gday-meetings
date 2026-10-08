import Foundation
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceLibraryStartupTests {
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func deferredLoadSharesWorkerAndLeavesMainActorAvailable() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let library = VoiceLibraryStore(
            directory: directory,
            beforeLoad: {
                #expect(!Thread.isMainThread)
                calls.withLock { $0 += 1 }
                entered.continuation.yield(())
                release.wait()
            })
        #expect(!library.isLoaded)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("voice-library").path))
        let first = Task { await library.awaitReady() }
        for await _ in entered.stream { break }
        let waiting = AsyncStream.makeStream(of: Void.self)
        let second = Task {
            waiting.continuation.yield(())
            return await library.awaitReady()
        }
        for await _ in waiting.stream { break }
        // This assertion runs on the UI actor while its storage worker is blocked.
        MainActor.assertIsolated()
        #expect(!library.isLoaded)
        #expect(!library.setJobs([]))
        second.cancel()
        release.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(library.isLoaded)
        #expect(calls.withLock { $0 } == 1)
        #expect(library.errorMessage == nil)
    }

    @Test func loadingRecoversJobsWithoutOpeningRepresentations() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = VoiceLibraryStore(loading: .immediate, directory: directory)
        let example = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system",
            embeddings: [.init(type: .community1, values: Array(repeating: 0, count: 256))])
        #expect(seed.upsert([example]))
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: false, exampleIDs: [example.id])
        job.state = .running
        #expect(seed.setJobs([job]))
        // Invalid vector JSON would fail hydration; metadata loading must not decode it.
        let vector = directory.appendingPathComponent("voice-library/representations/\(example.id.uuidString).json")
        try Data("invalid representation".utf8).write(to: vector)
        let library = VoiceLibraryStore(directory: directory)
        #expect(await library.awaitReady())
        #expect(library.jobs.first?.state == .paused)
        #expect(library.examples.count == 1)
        #expect(library.examples.first?.embeddings.isEmpty == true)
        #expect(library.hydratedExample(id: example.id) == nil)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.jobs.first?.state == .paused)
    }

    @Test func readOnlyLoadingPausesJobsWithoutChangingSavedState() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = VoiceLibraryStore(loading: .immediate, directory: directory)
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: .community1,
            discover: false, exampleIDs: [])
        job.state = .running
        #expect(seed.setJobs([job]))
        let header = directory.appendingPathComponent("voice-library/state.json")
        let original = try Data(contentsOf: header)
        let library = VoiceLibraryStore(directory: directory, canWrite: { false })
        #expect(await library.awaitReady())
        #expect(library.jobs.first?.state == .paused)
        #expect(try Data(contentsOf: header) == original)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.jobs.first?.state == .running)
    }

    @Test func failedLoadingDoesNotCreateStorageAndRejectsWrites() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory, beforeLoad: { throw ServiceError("Synthetic failure") })
        #expect(!(await library.awaitReady()))
        #expect(library.isLoaded)
        #expect(library.errorMessage?.contains("Synthetic failure") == true)
        #expect(!library.assign(meetingID: UUID(), speakerID: UUID(), personID: UUID()))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("voice-library").path))
    }

    @Test func unavailableVoiceLibraryDoesNotBlockTranscriptAdoption() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = await store.createMeeting(title: "Synthetic recording")
        let voiceDirectory = directory.appendingPathComponent("voice-library")
        try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
        let header = voiceDirectory.appendingPathComponent("state.json")
        let invalidHeader = Data("invalid voice metadata".utf8)
        try invalidHeader.write(to: header)
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en-US")
        draft.accept(.init(session: UUID(), source: .microphone, start: 0, end: 2, text: "Synthetic line"))
        #expect(await store.adoptLiveTranscript(draft))
        #expect(store.meeting(id: id)?.liveTranscriptAdopted == true)
        #expect(try TranscriptStorage.read(at: store.directory(for: id)) == draft.segments)
        #expect(try Data(contentsOf: header) == invalidHeader)
        #expect(await store.deleteMeeting(id: id))
        #expect(store.meeting(id: id) == nil)
    }

    @Test func failedVoiceLoadStillRecoversInterruptedTranscriptAfterLaunch() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = await store.createMeeting(title: "Synthetic interrupted recording")
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en-US")
        draft.accept(.init(session: UUID(), source: .microphone, start: 0, end: 2, text: "Synthetic line"))
        try draft.save(at: store.directory(for: id))
        let voiceDirectory = directory.appendingPathComponent("voice-library")
        try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
        let header = voiceDirectory.appendingPathComponent("state.json")
        let invalidHeader = Data("invalid voice metadata".utf8)
        try invalidHeader.write(to: header)
        let reopened = MeetingStore(dataDirectory: directory)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        #expect(!reopened.voiceLibrary.isLoaded)
        await reopened.prepareVoiceLibraryAfterLaunch()
        #expect(reopened.meeting(id: id)?.liveTranscriptAdopted == true)
        #expect(try TranscriptStorage.read(at: reopened.directory(for: id)) == draft.segments)
        #expect(try Data(contentsOf: header) == invalidHeader)
    }

    @Test func voiceRefreshFailureDoesNotBlockTranscriptAdoptionOrDeletion() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let id = await store.createMeeting(title: "Synthetic recording")
        let unresolved = VoiceExample(meetingID: id, speakerID: UUID(), source: "unknown")
        #expect(store.voiceLibrary.upsert([unresolved]))
        let commit = VoiceLibraryStore.CanonicalCommit(
            previous: .init(), next: .init(), persistence: .init(revision: nil, fileRevisions: [:], write: nil))
        store.voiceLibrary.finishCanonicalCommit(commit, state: nil, committed: false, refreshFailed: true)
        _ = store.voiceLibrary.resolveLegacyExample(
            exampleID: unresolved.id, meeting: try #require(store.meeting(id: id)), directory: store.directory(for: id))
        #expect(!(await store.voiceLibrary.awaitReady()))
        #expect(store.voiceLibrary.errorMessage?.contains("refresh the voice library") == true)
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en-US")
        draft.accept(.init(session: UUID(), source: .microphone, start: 0, end: 2, text: "Synthetic line"))
        #expect(await store.adoptLiveTranscript(draft))
        #expect(store.meeting(id: id)?.liveTranscriptAdopted == true)
        #expect(await store.deleteMeeting(id: id))
    }

}
