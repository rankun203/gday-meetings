import Foundation
import Testing

@testable import GdayMeetings

private final class VoiceMatchingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var entries = 0
    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }
    func wait() {
        lock.lock()
        entries += 1
        let shouldWait = !entered
        entered = true
        lock.unlock()
        if shouldWait { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}

@MainActor struct VoiceMatchingWorkerTests {
    private func fixture() throws -> (URL, VoiceLibraryStore, Person, VoiceExample) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let person = Person(name: "Alex")
        let example = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
            audioRevision: "synthetic", start: 0, end: 3, personID: person.id, review: .confirmed,
            embeddings: [.init(type: .community1SpeechSpan, values: [1] + Array(repeating: 0, count: 255))])
        #expect(library.upsert([example]))
        return (root, library, person, example)
    }

    private func awaitEntry(_ gate: VoiceMatchingGate) async throws {
        for _ in 0..<200 {
            if gate.started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ServiceError("The synthetic matching worker did not start.")
    }

    @Test func mainActorAndReviewRemainAvailableWhileWorkerIsPaused() async throws {
        let (root, library, person, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingRead = { gate.wait() }
        let matching = Task { try await library.matchingPeople(from: [person]) }
        try await awaitEntry(gate)
        var heartbeat = false
        await Task { @MainActor in heartbeat = true }.value
        #expect(heartbeat)
        // This commit must finish while the worker is paused, proving it holds no read lock.
        #expect(library.clear(ids: [example.id]))
        gate.release()
        do {
            _ = try await matching.value
            Issue.record("Matching published a profile after its review changed.")
        }
        catch {}
        library.beforeMatchingRead = nil
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
    }

    @Test func staleSuggestionCannotOverwriteManualClear() async throws {
        let (root, library, person, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var target = example
        target.id = UUID()
        target.speakerID = UUID()
        target.personID = nil
        target.suggestedPersonID = person.id
        target.review = .suggested
        target.start = 5
        target.end = 8
        #expect(library.upsert([target]))
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingRead = { gate.wait() }
        let matching = Task { await library.suggestReviewedPeople(from: [person]) }
        try await awaitEntry(gate)
        #expect(library.clear(ids: [target.id]))
        gate.release()
        await matching.value
        let current = try #require(library.examples.first { $0.id == target.id })
        #expect(current.manuallyCleared)
        #expect(current.suggestedPersonID == nil)
    }

    @Test func representationReplacementInvalidatesReadSnapshot() async throws {
        let (root, library, person, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingValidation = { gate.wait() }
        let matching = Task { try await library.matchingPeople(from: [person]) }
        try await awaitEntry(gate)
        let path = root.appendingPathComponent("voice-library/representations/\(example.id.uuidString).json")
        try JSONEncoder().encode(VoiceLibraryRepresentations(embeddings: [])).write(to: path, options: .atomic)
        gate.release()
        do {
            _ = try await matching.value
            Issue.record("Matching accepted a representation replaced outside its snapshot.")
        }
        catch {}
    }

    @Test func cancelledSuggestionKeepsExistingSuggestion() async throws {
        let (root, library, person, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var target = example
        target.id = UUID()
        target.personID = nil
        target.review = .suggested
        target.suggestedPersonID = person.id
        #expect(library.upsert([target]))
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingRead = { gate.wait() }
        let matching = Task { await library.suggestReviewedPeople(from: [person]) }
        try await awaitEntry(gate)
        matching.cancel()
        gate.release()
        await matching.value
        #expect(library.examples.first { $0.id == target.id }?.suggestedPersonID == person.id)
    }

    @Test func externalReviewMetadataChangeInvalidatesReadSnapshot() async throws {
        let (root, library, person, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingValidation = { gate.wait() }
        let matching = Task { try await library.matchingPeople(from: [person]) }
        try await awaitEntry(gate)
        var replacement = example
        replacement.personID = nil
        replacement.manuallyCleared = true
        replacement.embeddings = []
        let path = root.appendingPathComponent("voice-library/examples/\(example.id.uuidString).json")
        try JSONEncoder().encode(replacement).write(to: path, options: .atomic)
        gate.release()
        do {
            _ = try await matching.value
            Issue.record("Matching accepted review metadata replaced outside its snapshot.")
        }
        catch {}
    }

    @Test func cancellingOneCoalescedCallerKeepsOtherCallerRunning() async throws {
        let (root, library, person, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingRead = { gate.wait() }
        let first = Task { try await library.matchingPeople(from: [person]) }
        try await awaitEntry(gate)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await library.matchingPeople(from: [person])
        }
        while !secondStarted { await Task.yield() }
        first.cancel()
        gate.release()
        do {
            _ = try await first.value
            Issue.record("A cancelled matching caller returned profiles.")
        }
        catch is CancellationError {}
        #expect((try await second.value)[0].voiceSamples.count == 1)
        #expect(gate.entryCount == 1)
    }

    @Test func profileAndSuggestionRequestsDoNotCancelEachOther() async throws {
        let (root, library, person, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        library.beforeMatchingRead = { gate.wait() }
        let profiles = Task { try await library.matchingPeople(from: [person]) }
        try await awaitEntry(gate)
        var suggestionsStarted = false
        let suggestions = Task {
            suggestionsStarted = true
            await library.suggestReviewedPeople(from: [person])
        }
        while !suggestionsStarted { await Task.yield() }
        gate.release()
        #expect((try await profiles.value)[0].voiceSamples.count == 1)
        await suggestions.value
        #expect(library.errorMessage == nil)
        #expect(gate.entryCount == 2)
    }

    @Test func staleLiveSuggestionStillRetainsNewVoiceEvidence() async throws {
        let (root, _, _, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic recording")
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        store.recordingID = id
        defer { store.recordingID = nil }
        let gate = VoiceMatchingGate()
        defer { gate.release() }
        store.voiceLibrary.beforeMatchingRead = { gate.wait() }
        let sample = LiveSpeakerAudioSample(
            speakerID: UUID(), source: .microphone, generation: UUID(), start: 4, end: 7, samples: [])
        let recording = Task {
            await store.recordVoiceExample(meetingID: id, sample: sample, embedding: example.embeddings[0])
        }
        try await awaitEntry(gate)
        #expect(store.voiceLibrary.examples.contains { $0.speakerID == sample.speakerID })
        #expect(store.voiceLibrary.clear(ids: [example.id]))
        gate.release()
        await recording.value
        let retained = try #require(store.voiceLibrary.examples.first { $0.speakerID == sample.speakerID })
        #expect(retained.suggestedPersonID == nil)
        #expect(store.voiceLibrary.hydratedExample(id: retained.id)?.embeddings == example.embeddings)
    }

    @Test(arguments: [false, true]) func liveSuggestionsUseWorkerProfilesAndReviewedRejections(rejected: Bool)
        async throws
    {
        let (root, _, _, example) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        let personID = await store.addPerson(name: "Alex")
        #expect(store.voiceLibrary.confirm(ids: [example.id], personID: personID))
        if rejected {
            var rejection = example
            rejection.id = UUID()
            rejection.speakerID = UUID()
            rejection.meetingID = UUID()
            rejection.personID = nil
            rejection.review = .rejected
            rejection.rejectedPersonIDs = [personID]
            #expect(store.voiceLibrary.upsert([rejection]))
        }
        let id = await store.createMeeting(title: "Synthetic recording")
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        store.recordingID = id
        defer { store.recordingID = nil }
        let sample = LiveSpeakerAudioSample(
            speakerID: UUID(), source: .microphone, generation: UUID(), start: 4, end: 7, samples: [])
        await store.recordVoiceExample(meetingID: id, sample: sample, embedding: example.embeddings[0])
        let retained = try #require(store.voiceLibrary.examples.first { $0.speakerID == sample.speakerID })
        #expect(retained.suggestedPersonID == (rejected ? nil : personID))
        #expect(store.voiceLibrary.hydratedExample(id: retained.id)?.embeddings == example.embeddings)
        #expect(store.voiceLibrary.examples.first { $0.id == example.id }?.review == .confirmed)
    }
}
