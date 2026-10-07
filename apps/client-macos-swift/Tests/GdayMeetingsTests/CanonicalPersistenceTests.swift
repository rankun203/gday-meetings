import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct CanonicalPersistenceTests {
    @Test func rapidNavigationSkipsAbandonedQueuedReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        var ids: [UUID] = []
        for index in 0..<20 { ids.append(await store.createMeeting(title: "Synthetic page \(index)")) }
        store.clearLoadedMeetingCache()
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.meetingLoadReader = { id, directory in
            try gate.enter()
            return try MeetingFolderStorage.read(id: id, directory: directory)
        }
        var pages: [Task<Bool, Never>] = []
        pages.append(Task { await store.ensureMeetingLoaded(id: ids[0]) })
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        for id in ids.dropFirst() {
            pages.last?.cancel()
            pages.append(Task { await store.ensureMeetingLoaded(id: id) })
            await Task.yield()
        }
        try #require(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.meetingLoadQueue.pendingCount == 1 && store.meetingLoadOperations.count == 2
            })
        #expect(gate.callCount == 1)
        for page in pages.dropFirst().dropLast() { #expect(await page.value == false) }
        gate.release()
        for page in pages.dropLast() { #expect(await page.value == false) }
        #expect(await pages.last!.value)
        #expect(gate.callCount == 2)
        #expect(store.meeting(id: ids.last!) != nil)
        #expect(ids.dropLast().allSatisfy { store.meeting(id: $0) == nil })
        #expect(store.meetingLoadOperations.isEmpty)
    }

    @Test(arguments: [false, true])
    func queuedReadHonorsDeletionAndLibraryChanges(_ changingLibrary: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let first = await store.createMeeting(title: "Synthetic held page")
        let second = await store.createMeeting(title: "Synthetic queued page")
        store.clearLoadedMeetingCache()
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.meetingLoadReader = { id, directory in
            try gate.enter()
            return try MeetingFolderStorage.read(id: id, directory: directory)
        }
        let held = Task { await store.ensureMeetingLoaded(id: first) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        let queued = Task { await store.ensureMeetingLoaded(id: second) }
        try #require(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.meetingLoadQueue.pendingCount == 1
            })
        if changingLibrary {
            store.externalReloadGeneration = UUID()
        }
        else {
            store.deletingMeetingIDs.formUnion([first, second])
        }
        gate.release()
        #expect(await held.value == false)
        #expect(await queued.value == false)
        #expect(gate.callCount == 1)
        #expect(store.meeting(id: first) == nil)
        #expect(store.meeting(id: second) == nil)
        #expect(store.meetingLoadQueue.pendingCount == 0)
        #expect(store.meetingLoadOperations.isEmpty)
    }

    @Test func independentReviewCancelledPageDoesNotPublishAbandonedMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic abandoned page")
        store.clearLoadedMeetingCache()
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.meetingLoadReader = { id, directory in
            try gate.enter()
            return try MeetingFolderStorage.read(id: id, directory: directory)
        }
        let page = Task { await store.ensureMeetingLoaded(id: id) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        page.cancel()
        gate.release()
        #expect(await page.value == false)
        #expect(store.meeting(id: id) == nil, "An abandoned page with no remaining consumers must not publish its load")
    }

    @Test(arguments: [false, true])
    func delayedSavePreservesNewerEditsAndOrdersFollowingCommit(_ failFirst: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original")
        let gate = CanonicalWriteGate(failFirst: failFirst)
        defer { gate.release() }
        store.canonicalWriteHook = { try gate.enter() }
        var first = try #require(store.meeting(id: id))
        first.title = "First revision"
        let firstWrite = Task { await store.updateMeeting(first) }
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        #expect(!gate.wasMainThread)
        var second = try #require(store.meeting(id: id))
        second.title = "Second revision"
        let secondWrite = Task { await store.updateMeeting(second) }
        #expect(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.meeting(id: id)?.title == "Second revision"
            })
        firstWrite.cancel()  // An admitted durable command must finish despite caller cancellation.
        gate.release()
        #expect(await firstWrite.value == !failFirst)
        #expect(await secondWrite.value)
        #expect(store.meeting(id: id)?.title == "Second revision")
        #expect(try MeetingFolderStorage.read(id: id, directory: root).title == "Second revision")
        #expect(await store.flushCanonicalWrites())
    }

    @Test func delayedCompletionDoesNotReplaceUnsavedNewerMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original")
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.canonicalWriteHook = { try gate.enter() }
        var value = try #require(store.meeting(id: id))
        value.summary = "Committed summary"
        let save = Task { await store.updateMeeting(value) }
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        store.meetings[0].title = "Newer local title"
        gate.release()
        #expect(await save.value)
        #expect(store.meeting(id: id)?.title == "Newer local title")
        #expect(try MeetingFolderStorage.read(id: id, directory: root).title == "Original")
        #expect(await store.updateMeeting(try #require(store.meeting(id: id))))
        #expect(try MeetingFolderStorage.read(id: id, directory: root).title == "Newer local title")
    }

    @Test func externalConflictPreservesDiskAndRollsBackOnlyCapturedEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original")
        var remote = try #require(store.meeting(id: id))
        remote.title = "External edit"
        try MeetingFolderStorage.write(remote, directory: root)
        var local = try #require(store.meeting(id: id))
        local.summary = "Local summary"
        #expect(!(await store.updateMeeting(local)))
        #expect(store.meeting(id: id)?.summary.isEmpty == true)
        #expect(try MeetingFolderStorage.read(id: id, directory: root).title == "External edit")
    }

    @Test func deletionDrainsAdmittedSaveAndRejectsLaterEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original")
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.canonicalWriteHook = { try gate.enter() }
        var value = try #require(store.meeting(id: id))
        value.title = "Admitted edit"
        let save = Task { await store.updateMeeting(value) }
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        let deletion = Task { await store.deleteMeeting(id: id) }
        #expect(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.deletingMeetingIDs.contains(id)
            })
        value.title = "Too late"
        #expect(!(await store.updateMeeting(value)))
        gate.release()
        #expect(await save.value)
        #expect(await deletion.value)
        #expect(store.meeting(id: id) == nil)
        #expect(!(await store.ensureMeetingLoaded(id: id)))
    }

    @Test func quitFlushesPendingNotesAfterFreezingNewSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Notes draft")
        store.editNotes(id: id, text: "Latest draft")
        #expect(store.notesStorage.pending[id] == "Latest draft")
        #expect(await store.finalizeForQuit())
        #expect(store.notesStorage.pending.isEmpty)
        #expect(try MeetingFolderStorage.read(id: id, directory: root).notes == "Latest draft")
    }

    @Test(arguments: ["file", "ancestor", "generation"])
    func coldReadRetriesExternalChangesWithoutPublishingOldSnapshot(_ change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original snapshot")
        var updated = try #require(store.meeting(id: id))
        store.clearLoadedMeetingCache()
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.meetingLoadReader = { id, directory in
            let snapshot = try MeetingFolderStorage.read(id: id, directory: directory)
            try gate.enter()
            return snapshot
        }
        let load = Task { await store.ensureMeetingLoaded(id: id) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        updated.title = "Current snapshot"
        try MeetingFolderStorage.write(updated, directory: root)
        if change == "generation" {
            store.externalReloadGeneration = UUID()
        }
        else {
            store.requestExternalLibraryReload(
                paths: [change == "ancestor" ? root : store.directory(for: id).appendingPathComponent("metadata.json")],
                rebuild: false)
        }
        gate.release()
        #expect(await load.value == (change != "generation"))
        #expect(gate.callCount == (change == "generation" ? 1 : 2))
        #expect(store.meeting(id: id)?.title == (change == "generation" ? nil : "Current snapshot"))
    }

    @Test(arguments: [false, true])
    func concurrentColdConsumersShareReadAndCancellationIsIndependent(_ cancelFirst: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Cold meeting")
        store.clearLoadedMeetingCache()
        let gate = CanonicalWriteGate()
        defer { gate.release() }
        store.meetingLoadReader = { id, directory in
            try gate.enter()
            return try MeetingFolderStorage.read(id: id, directory: directory)
        }
        let first = Task { await store.ensureMeetingLoaded(id: id) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await store.ensureMeetingLoaded(id: id)
        }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { secondStarted })
        if cancelFirst { first.cancel() }
        gate.release()
        #expect(await first.value == !cancelFirst)
        #expect(await second.value)
        #expect(gate.callCount == 1)
        #expect(!gate.wasMainThread)
        #expect(store.meeting(id: id)?.title == "Cold meeting")
    }
}

private final class CanonicalWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    private var mainThread = false
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls > 0
    }
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    var wasMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThread
    }
    func enter() throws {
        lock.lock()
        calls += 1
        let first = calls == 1
        mainThread = mainThread || Thread.isMainThread
        lock.unlock()
        if first {
            semaphore.wait()
            if failFirst { throw MeetingError.message("Synthetic write failure") }
        }
    }
    func release() { semaphore.signal() }
}
