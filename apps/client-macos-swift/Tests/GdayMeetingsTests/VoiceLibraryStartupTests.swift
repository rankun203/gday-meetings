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

    @Test(arguments: [false, true])
    func liveAssignmentAcceptedBeforeStopSurvivesPendingVoiceLoad(correctAfterStop: Bool) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let personID = await store.addPerson(name: "Synthetic person")
        let correctedPersonID = await store.addPerson(name: "Another synthetic person")
        let id = await store.createMeeting(title: "Synthetic recording")
        let speakerID = UUID()
        var meeting = try #require(store.meeting(id: id))
        meeting.speakers = [.init(id: speakerID, label: "Voice 1", track: "system", providerName: "Synthetic provider")]
        #expect(await store.updateMeeting(meeting))
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        store.voiceLibrary = VoiceLibraryStore(
            directory: directory,
            beforeLoad: {
                entered.continuation.yield(())
                release.wait()
            })
        store.recordingID = id
        let assignment = Task {
            await store.enrollLiveVoice(meetingID: id, personID: personID, speakerID: speakerID, embedding: nil)
        }
        for await _ in entered.stream { break }
        store.recordingID = nil
        let correcting = AsyncStream.makeStream(of: Void.self)
        let correction = Task {
            if correctAfterStop {
                correcting.continuation.yield(())
                await store.assignSpeaker(meetingID: id, speakerID: speakerID, personID: correctedPersonID)
            }
        }
        if correctAfterStop { for await _ in correcting.stream { break } }
        release.signal()
        await assignment.value
        await correction.value
        let expectedPersonID = correctAfterStop ? correctedPersonID : personID
        #expect(
            store.voiceLibrary.decisions.contains {
                $0.meetingID == id && $0.speakerID == speakerID && $0.personID == expectedPersonID
            })
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.decisions == store.voiceLibrary.decisions)
    }

    @Test func replacedQueuedEnrollmentDoesNotFailLaterCorrection() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let first = await store.addPerson(name: "First synthetic person")
        let second = await store.addPerson(name: "Second synthetic person")
        let id = await store.createMeeting(title: "Synthetic recording")
        let speakerID = UUID()
        var meeting = try #require(store.meeting(id: id))
        meeting.speakers = [.init(id: speakerID, label: "Voice 1", track: "system", providerName: "Synthetic provider")]
        #expect(await store.updateMeeting(meeting))
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        store.canonicalWriteHook = {
            entered.continuation.yield(())
            release.wait()
        }
        meeting.title = "Synthetic updated recording"
        let saving = Task { await store.updateMeeting(meeting) }
        for await _ in entered.stream { break }
        store.canonicalWriteHook = nil
        store.recordingID = id
        let queued = AsyncStream.makeStream(of: Void.self)
        let enrollment = Task {
            queued.continuation.yield(())
            await store.enrollLiveVoice(meetingID: id, personID: first, speakerID: speakerID, embedding: nil)
        }
        for await _ in queued.stream { break }
        store.recordingID = nil
        let correcting = AsyncStream.makeStream(of: Void.self)
        let correction = Task {
            correcting.continuation.yield(())
            await store.assignSpeaker(meetingID: id, speakerID: speakerID, personID: second)
        }
        for await _ in correcting.stream { break }
        release.signal()
        #expect(await saving.value)
        await enrollment.value
        await correction.value
        #expect(await store.flushCanonicalWrites())
        #expect(store.meeting(id: id)?.speakers.first?.personID == second)
        #expect(store.voiceLibrary.decisions.first?.personID == second)
    }

    @Test func transcriptAdoptionWaitsForEnrollmentBeforeFinalizingConvertedSample() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let personID = await store.addPerson(name: "Synthetic person")
        let id = await store.createMeeting(title: "Synthetic recording")
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = ["system.m4a"]
        #expect(await store.updateMeeting(meeting))
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let audio = store.directory(for: id).appendingPathComponent("system.m4a")
        try Data("synthetic audio fixture".utf8).write(to: audio)
        let generation = UUID()
        let identity = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: generation, slot: 0,
            model: "synthetic", revision: "v1")
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en-US")
        draft.speakerTimeline = LiveSpeakerTimeline()
        #expect(
            draft.speakerTimeline?.accept(
                .init(
                    source: .system, generation: generation, sequence: 0, speakers: [identity],
                    intervals: [.init(speakerID: identity.id, start: 0, end: 4)], start: 0, end: 4)) == true)
        draft.accept(.init(session: UUID(), source: .system, start: 0, end: 4, text: "Synthetic line"))
        let example = VoiceExample(
            meetingID: id, speakerID: identity.id, source: "system", audioFile: "system.wav", start: 0, end: 4)
        #expect(store.voiceLibrary.upsert([example]))
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        store.canonicalWriteHook = {
            entered.continuation.yield(())
            release.wait()
        }
        store.recordingID = id
        store.isFinalizingRecording = true
        let enrollment = Task {
            await store.enrollLiveVoice(meetingID: id, personID: personID, speakerID: identity.id, embedding: nil)
        }
        for await _ in entered.stream { break }
        store.canonicalWriteHook = nil
        let adopting = AsyncStream.makeStream(of: Void.self)
        let adoption = Task {
            adopting.continuation.yield(())
            return await store.adoptLiveTranscript(draft)
        }
        for await _ in adopting.stream { break }
        release.signal()
        await enrollment.value
        #expect(await adoption.value)
        #expect(store.voiceLibrary.examples.first?.audioFile == "system.m4a")
        #expect(store.voiceLibrary.examples.first?.audioRevision == VoiceLibraryStore.revision(url: audio))
    }
}
