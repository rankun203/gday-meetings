import Foundation
import Testing

@testable import GdayMeetings

private final class ProfileReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var entered = false
    private var entries = 0
    private var cancelledWaiterFinished = false
    var cancellationObserved: Bool { lock.withLock { cancelledWaiterFinished } }
    func markCancellation() { lock.withLock { cancelledWaiterFinished = true } }
    var entryCount: Int { lock.withLock { entries } }
    var started: Bool { lock.withLock { entered } }
    func wait() {
        lock.withLock {
            entered = true
            entries += 1
        }
        signal.wait()
    }
    func release() { signal.signal() }
}

struct VoiceProfileCacheTests {
    private func example(person: Person) -> VoiceExample {
        .init(
            meetingID: UUID(), speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
            start: 0, end: 3, personID: person.id, review: .confirmed,
            embeddings: [.init(type: .community1SpeechSpan, values: [1] + Array(repeating: 0, count: 255))])
    }
    private func input(_ backend: VoiceLibraryPersistence, root: URL, person: Person) throws
        -> VoiceMatchingWorker.Input
    {
        let document = try #require(try backend.load())
        return .init(
            directory: root, persistence: backend.snapshot(), examples: document.examples,
            people: [person], deletedPeople: [], includeSuggestions: false)
    }
    @Test func unreviewedUpdatesReuseProfilesButReviewedRepresentationsInvalidateThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        let person = Person(name: "Reviewed voice")
        var document = VoiceLibraryDocument()
        document.examples = [example(person: person)]
        try backend.commit(previous: .init(), next: document)
        let worker = VoiceMatchingWorker()
        let first = try await worker.run(
            input(backend, root: root, person: person), beforeRead: nil, beforeValidation: nil)
        #expect(first.profiles[0].voiceSamples.count == 1)
        var next = document
        var candidate = example(person: person)
        candidate.personID = nil
        candidate.review = .unassigned
        next.examples.append(candidate)
        try backend.commit(previous: document, next: next)
        document = next
        _ = try await worker.run(input(backend, root: root, person: person), beforeRead: nil, beforeValidation: nil)
        #expect(await worker.profileBuildCount == 1)
        next.examples[0].embeddings[0].values = [0, 1] + Array(repeating: 0, count: 254)
        try backend.commit(previous: document, next: next)
        let changed = try await worker.run(
            input(backend, root: root, person: person), beforeRead: nil, beforeValidation: nil)
        #expect(await worker.profileBuildCount == 2)
        #expect(changed.profiles[0].voiceSamples[0].voiceEmbedding?.values[1] == 1)
    }
    @Test func cancelledCandidateWaiterDoesNotCancelSharedReviewedProfileWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        let person = Person(name: "Reviewed voice")
        var document = VoiceLibraryDocument()
        document.examples = [example(person: person)]
        try backend.commit(previous: .init(), next: document)
        let snapshot = try input(backend, root: root, person: person)
        let gate = ProfileReadGate()
        defer { gate.release() }
        let worker = VoiceMatchingWorker(beforeProfileRead: { gate.wait() })
        let first = Task {
            do { return try await worker.run(snapshot, beforeRead: nil, beforeValidation: nil) }
            catch {
                if error is CancellationError { gate.markCancellation() }
                throw error
            }
        }
        for _ in 0..<100 where !gate.started { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.started)
        first.cancel()
        for _ in 0..<100 where !gate.cancellationObserved { try await Task.sleep(for: .milliseconds(10)) }
        // A cancelled live snapshot is released while the shared profile remains
        // deliberately blocked, rather than retaining the whole library input.
        #expect(gate.cancellationObserved)
        #expect(await worker.profileBuildCount == 1)
        let second = Task { try await worker.run(snapshot, beforeRead: nil, beforeValidation: nil) }
        gate.release()
        do {
            _ = try await first.value
            Issue.record("Cancelled waiter published a result")
        }
        catch is CancellationError {}
        catch { throw error }
        #expect(try await second.value.profiles[0].voiceSamples.count == 1)
        #expect(await worker.profileBuildCount == 1)
    }
    @Test func coldProfilesUseAtMostTwoWorkerPermits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        let people = (0..<5).map { Person(name: "Person \($0)") }
        var document = VoiceLibraryDocument()
        document.examples = people.map { example(person: $0) }
        try backend.commit(previous: .init(), next: document)
        let loaded = try #require(try backend.load())
        let snapshot = VoiceMatchingWorker.Input(
            directory: root, persistence: backend.snapshot(), examples: loaded.examples,
            people: people, deletedPeople: [], includeSuggestions: false)
        let gate = ProfileReadGate()
        defer { for _ in people { gate.release() } }
        let worker = VoiceMatchingWorker(beforeProfileRead: { gate.wait() })
        let matching = Task { try await worker.run(snapshot, beforeRead: nil, beforeValidation: nil) }
        for _ in 0..<100 where gate.entryCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.entryCount == 2)
        #expect(await worker.maximumConcurrentProfileBuilds == 2)
        for _ in people { gate.release() }
        #expect(try await matching.value.profiles.count == people.count)
        #expect(await worker.maximumConcurrentProfileBuilds == 2)
    }

    @Test func externalRepresentationEditCannotReuseCachedProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        let person = Person(name: "Reviewed voice")
        let voice = example(person: person)
        var document = VoiceLibraryDocument()
        document.examples = [voice]
        try backend.commit(previous: .init(), next: document)
        let snapshot = try input(backend, root: root, person: person)
        let worker = VoiceMatchingWorker()
        _ = try await worker.run(snapshot, beforeRead: nil, beforeValidation: nil)
        let path = root.appendingPathComponent("voice-library/representations/\(voice.id.uuidString).json")
        try Data("{\"embeddings\":[]}".utf8).write(to: path)
        do {
            _ = try await worker.run(snapshot, beforeRead: nil, beforeValidation: nil)
            Issue.record("External edit reused stale profile")
        }
        catch {}
    }
}
