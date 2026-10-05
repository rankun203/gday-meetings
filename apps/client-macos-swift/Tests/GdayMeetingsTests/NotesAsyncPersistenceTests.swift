import Foundation
import Testing

@testable import GdayMeetings

private final class NotesWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var started = false
    private var calls = 0
    var hasStarted: Bool { lock.withLock { started } }
    func pauseFirst() throws {
        let first = lock.withLock {
            calls += 1
            if calls == 1 { started = true }
            return calls == 1
        }
        guard first else { return }
        guard !Thread.isMainThread else { throw ServiceError("Notes I/O ran on the main thread.") }
        // The test owns the bounded admission wait and always releases in defer.
        // An independent worker deadline would expire while unrelated UI tests
        // occupy MainActor, before the test can perform its queued edit.
        releaseGate.wait()
    }
    func release() { releaseGate.signal() }
}

@MainActor struct NotesAsyncPersistenceTests {
    @Test func deletionReservationDrainsExistingDraftAndRejectsNewEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = NotesStorage(directory: root)
        let id = UUID()
        storage.schedule(id, text: "Admitted draft")
        #expect(storage.reserveDeletion(id))
        defer { storage.releaseDeletion(id) }
        storage.schedule(id, text: "Late edit")
        #expect(storage.pending[id] == "Admitted draft")
        await #expect(throws: (any Error).self) { try await storage.discard(id) }
        #expect(storage.pending[id] == "Admitted draft")
        try await storage.flush(id)
        #expect(try String(contentsOf: storage.url(id), encoding: .utf8) == "Admitted draft")
        try await storage.discard(id)
        #expect(storage.saved[id] == nil)
    }

    @Test func delayedWritePreservesAndFlushesNewestEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NotesWriteGate()
        defer { gate.release() }
        let worker = NotesFileWorker(directory: root, beforeWrite: { _, _ in try gate.pauseFirst() })
        let storage = NotesStorage(directory: root, worker: worker)
        let id = UUID()
        storage.schedule(id, text: "First edit")
        let flush = Task { try await storage.flush(id) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(2)) { gate.hasStarted })
        // This executes on the main actor while the worker is blocked on disk work.
        storage.schedule(id, text: "Last character!")
        #expect(storage.pending[id] == "Last character!")
        gate.release()
        try await flush.value
        #expect(storage.pending[id] == nil)
        #expect(storage.saved[id] == "Last character!")
        #expect(try String(contentsOf: storage.url(id), encoding: .utf8) == "Last character!")
        #expect(
            !FileManager.default.fileExists(
                atPath: storage.url(id).deletingLastPathComponent()
                    .appendingPathComponent("notes (changed on disk).md").path))
    }

    @Test func delayedReadCannotReplaceAnEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let gate = NotesWriteGate()
        defer { gate.release() }
        let storage = NotesStorage(
            directory: root,
            worker: NotesFileWorker(directory: root, beforeRead: { _ in try gate.pauseFirst() }))
        let load = Task { try await storage.load(id, fallback: "Old notes") }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(2)) { gate.hasStarted })
        storage.schedule(id, text: "New draft")
        gate.release()
        #expect(try await load.value == "New draft")
        #expect(storage.pending[id] == "New draft")
        try await storage.flushAll()
        #expect(storage.saved[id] == "New draft")
    }

    @Test func failedWriteRetainsDraftUntilRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = NotesStorage(directory: root)
        let id = UUID()
        let folder = storage.url(id).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Blocked".utf8).write(to: folder)
        storage.schedule(id, text: "Keep this draft")
        await #expect(throws: (any Error).self) { try await storage.flushAll() }
        #expect(storage.pending[id] == "Keep this draft")
        try FileManager.default.removeItem(at: folder)
        try await storage.flushAll()
        #expect(storage.pending[id] == nil)
        #expect(try String(contentsOf: storage.url(id), encoding: .utf8) == "Keep this draft")
    }
}
