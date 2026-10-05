import Foundation
import Testing

@testable import GdayMeetings

private final class TaskStorageLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    var isWaiting: Bool { lock.withLock { entered } }
    func block() {
        lock.withLock { entered = true }
        release.wait()
    }
    func resume() { release.signal() }
}

@MainActor struct ManagedTaskIOTests {
    @Test func blockedStorageKeepsUIResponsiveAndReservationsRejectDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Storage delay")
        let latch = TaskStorageLatch()
        defer { latch.resume() }
        // Fail after the blocking read: no provider can start from this intent.
        store.managedTaskIO = ManagedTaskIO {
            if !latch.isWaiting { latch.block() }
            throw ServiceError("Synthetic storage failure")
        }
        let enqueue = Task { await store.queueSummary(id: id) }
        let entered = try await waitForMainActorTestCondition { latch.isWaiting }
        guard entered else {
            latch.resume()
            Issue.record("Storage worker did not start")
            return
        }
        for _ in 0..<1_000 { #expect(store.isJobRunning(.summary, .meeting(id))) }
        #expect(await store.queueSummary(id: id) == nil)
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.managedTasks.isEmpty)
        latch.resume()
        #expect(await enqueue.value == nil)
        await store.flushManagedTaskCommands()
        #expect(store.managedTaskReservations.isEmpty)
        #expect(!store.isJobRunning(.summary, .meeting(id)))
        #expect(store.managedTaskJournalError?.contains("Synthetic storage failure") == true)
    }

    @Test func cancellationDuringStorageWaitPreventsProviderRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"content":"Summary"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let store = MeetingStore(dataDirectory: root)
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.endpoint = server.origin + "/v1"
        provider.model = "fixture"
        provider.enabledCapabilities = [.summarization]
        store.settings.serviceProviders = [provider]
        store.settings.summaryProviderID = provider.id
        let id = await store.createMeeting(title: "Cancel before submission")
        var meeting = try #require(store.meeting(id: id))
        meeting.transcript = [.init(text: "Synthetic transcript")]
        #expect(await store.updateMeeting(meeting))
        let journal = store.managedTaskJournal
        let latch = TaskStorageLatch()
        defer { latch.resume() }
        store.managedTaskIO = ManagedTaskIO {
            if !latch.isWaiting, try journal.query(where: "state='queued'", limit: 1).first != nil {
                latch.block()
            }
        }
        let enqueue = Task { await store.queueSummary(id: id) }
        let entered = try await waitForMainActorTestCondition { latch.isWaiting }
        guard entered else {
            latch.resume()
            Issue.record("Queued intent did not reach storage barrier")
            return
        }
        let task = try #require(store.managedTasks.first)
        let cancel = Task { await store.cancelManagedTask(id: task.id) }
        let reserved = try await waitForMainActorTestCondition { store.managedTaskStopRequests.contains(task.id) }
        #expect(reserved)
        #expect(server.requests.isEmpty)
        latch.resume()
        _ = await enqueue.value
        await cancel.value
        await store.flushManagedTaskCommands()
        #expect(store.managedTask(id: task.id)?.state == .cancelled)
        #expect(server.requests.isEmpty)
        let persisted = try await store.managedTaskIO.perform { journal.record(id: task.id) }
        #expect(persisted?.state == .cancelled)
    }

    @Test func schedulerReadFailureLeavesDurableIntentButDoesNotHangWaiters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Scheduling failure")
        let journal = store.managedTaskJournal
        store.managedTaskIO = ManagedTaskIO {
            if try journal.query(where: "state='queued'", limit: 1).first != nil {
                throw ServiceError("Synthetic scheduler read failure")
            }
        }
        let taskID = try #require(await store.queueSummary(id: id))
        await store.waitForManagedTask(taskID)
        #expect(store.managedTask(id: taskID)?.state == .failed)
        #expect(store.backgroundJobs.isEmpty)
        #expect(store.managedTaskWaiters.isEmpty)
        let persisted = try await ManagedTaskIO().perform { journal.record(id: taskID) }
        #expect(persisted?.state == .queued)
        #expect(store.managedTaskJournalError?.contains("Synthetic scheduler read failure") == true)
    }

    @Test func quitDuringSchedulingKeepsUnsubmittedTaskQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Quit before submission")
        let journal = store.managedTaskJournal
        let latch = TaskStorageLatch()
        defer { latch.resume() }
        store.managedTaskIO = ManagedTaskIO {
            if !latch.isWaiting, try journal.query(where: "state='queued'", limit: 1).first != nil {
                latch.block()
            }
        }
        let enqueue = Task { await store.queueSummary(id: id) }
        let entered = try await waitForMainActorTestCondition { latch.isWaiting }
        guard entered else {
            latch.resume()
            Issue.record("Queued intent did not reach storage barrier")
            return
        }
        let closing = Task { await store.prepareManagedTasksForQuit() }
        let frozen = try await waitForMainActorTestCondition { store.isPreparingToQuit }
        #expect(frozen)
        #expect(await store.queueSummary(id: UUID()) == nil)
        latch.resume()
        let taskID = try #require(await enqueue.value)
        #expect(await closing.value)
        let persisted = try await store.managedTaskIO.perform { journal.record(id: taskID) }
        #expect(persisted?.state == .queued)
        #expect(store.managedTaskOperations.isEmpty)
        #expect(store.managedTaskCommands.isIdle)
    }

    @Test func commandsRemainFIFOWhenCallerIsCancelled() async throws {
        let commands = ManagedTaskCommands()
        let worker = ManagedTaskIO()
        let latch = TaskStorageLatch()
        defer { latch.resume() }
        var order: [Int] = []
        let first = Task {
            await commands.run {
                order.append(1)
                try? await worker.perform { latch.block() }
                order.append(2)
            }
        }
        let entered = try await waitForMainActorTestCondition { latch.isWaiting }
        guard entered else {
            latch.resume()
            Issue.record("Storage worker did not start")
            return
        }
        first.cancel()
        let second = Task { await commands.run { order.append(3) } }
        await Task.yield()
        #expect(order == [1])
        latch.resume()
        await first.value
        await second.value
        await commands.drain()
        #expect(order == [1, 2, 3])
        #expect(commands.isIdle)
    }

    @Test(arguments: [false, true])
    func quitRejectsLateLifecycleCallbacksBeforeCommandAdmission(recovery: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let latch = TaskStorageLatch()
        defer { latch.resume() }
        let worker = ManagedTaskIO()
        let admitted = Task {
            await store.managedTaskCommands.run { try? await worker.perform { latch.block() } }
        }
        let entered = try await waitForMainActorTestCondition { latch.isWaiting }
        guard entered else {
            latch.resume()
            Issue.record("Existing command did not reach the storage gate")
            return
        }
        store.isPreparingToQuit = true
        var returned = false
        let callback = Task {
            if recovery {
                await store.recoverUnfinishedManagedTasks()
            }
            else {
                await store.reloadExternalManagedTasks()
            }
            returned = true
        }
        // A late file-monitor or wake callback must return without joining the
        // occupied gate; otherwise another command can appear after quit drains.
        let rejected = try await waitForMainActorTestCondition { returned }
        #expect(rejected)
        #expect(store.managedTaskCommands.pending == 1)
        latch.resume()
        _ = await admitted.value
        await callback.value
        await store.flushManagedTaskCommands()
        #expect(store.managedTaskCommands.isIdle)
    }

    @Test func activeProjectionIncludesTasksOutsidePayloadCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let journal = store.managedTaskJournal
        let records = (0..<130).map { index in
            ManagedTaskRecord(
                kind: .summary, meetingID: UUID(), meetingTitle: "Queued task \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        try await store.managedTaskIO.perform {
            for record in records { try journal.upsert(record) }
        }
        try await store.restoreManagedTasks()
        #expect(store.managedTasks.count == 100)
        #expect(store.managedTask(id: records[0].id) == nil)
        #expect(store.isJobRunning(.summary, .meeting(records[0].meetingID)))
        #expect(store.managedTaskStateCounts[.queued] == 130)
        try await store.managedTaskIO.perform { try journal.delete(records[0].id) }
        try await store.restoreManagedTasks()
        #expect(!store.isJobRunning(.summary, .meeting(records[0].meetingID)))
        #expect(store.managedTaskStateCounts[.queued] == 129)
        store.isSchedulingManagedTasks = true
        var finished = false
        let waiting = Task {
            await store.waitForManagedTask(records[1].id)
            finished = true
        }
        let registered = try await waitForMainActorTestCondition {
            store.managedTaskWaiters[records[1].id]?.isEmpty == false
        }
        #expect(registered)
        #expect(!finished)
        await store.cancelManagedTask(id: records[1].id)
        await waiting.value
        #expect(finished)
        let externallyRemoved = Task { await store.waitForManagedTask(records[2].id) }
        let secondRegistered = try await waitForMainActorTestCondition {
            store.managedTaskWaiters[records[2].id]?.isEmpty == false
        }
        #expect(secondRegistered)
        try await store.managedTaskIO.perform { try journal.delete(records[2].id) }
        try await store.restoreManagedTasks()
        await externallyRemoved.value
        #expect(store.managedTaskWaiters[records[2].id] == nil)
    }
}
