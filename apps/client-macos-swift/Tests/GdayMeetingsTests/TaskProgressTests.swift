import Foundation
import Testing

@testable import GdayMeetings

struct TaskProgressTests {
    @Test func fractionsRequireMeasuredFiniteWork() {
        #expect(TaskProgress(phase: "Preparing").fractionCompleted == nil)
        #expect(TaskProgress(phase: "Indexing", completed: 1, total: 0).fractionCompleted == nil)
        #expect(TaskProgress(phase: "Indexing", completed: .nan, total: 4).fractionCompleted == nil)
        #expect(TaskProgress(phase: "Indexing", completed: -1, total: 4).fractionCompleted == nil)
        #expect(TaskProgress(phase: "Indexing", completed: 2, total: 4).fractionCompleted == 0.5)
        #expect(TaskProgress(phase: "Indexing", completed: 5, total: 4).fractionCompleted == 1)
    }

    @Test func elapsedTimeDoesNotAdvanceMeasuredProgress() {
        let progress = TaskProgress(
            phase: "Transcribing", completed: 20, total: 100,
            startedAt: Date(timeIntervalSince1970: 0), estimatedRemainingSeconds: 0)
        #expect(progress.fractionCompleted == 0.2)
        #expect(progress.remainingTimeText == nil)
    }

    @MainActor @Test func performanceSamplesAreIsolatedAndExpire() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = TaskPerformanceCache(url: root.appendingPathComponent("rates.json"))
        let key = TaskPerformanceKey(operation: "embedding", provider: "local", model: "example")
        let alternate = TaskPerformanceKey(operation: "embedding", provider: "local", model: "other")
        let now = Date()
        #expect(cache.estimate(key: key, remainingUnits: 10, now: now) == nil)
        cache.record(key: key, completedUnits: 10, elapsedSeconds: 20, now: now)
        cache.record(key: key, completedUnits: 0, elapsedSeconds: 20, now: now)
        cache.record(key: key, completedUnits: 10, elapsedSeconds: .infinity, now: now)
        #expect(cache.estimate(key: key, remainingUnits: 5, now: now) == 10)
        #expect(cache.estimate(key: alternate, remainingUnits: 5, now: now) == nil)
        #expect(cache.estimate(key: key, remainingUnits: 5, now: now.addingTimeInterval(31 * 86400)) == nil)
        #expect(cache.estimate(key: key, remainingUnits: .infinity, now: now) == nil)
    }

    @MainActor @Test func lateAttemptCallbacksCannotUpdateReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = UUID()
        #expect(store.beginJob(.transcription, .meeting(id), progress: "Preparing"))
        let oldAttempt = try #require(store.jobProgressAttemptID(.transcription, .meeting(id)))
        store.setJobProgress(
            .transcription, .meeting(id), "Transcribing",
            details: .init(phase: "Transcribing", completed: 1, total: 10), attemptID: oldAttempt)
        // A second update is pending in the coalescing window when the job ends.
        store.setJobProgress(
            .transcription, .meeting(id), "Transcribing",
            details: .init(phase: "Transcribing", completed: 2, total: 10), attemptID: oldAttempt)
        store.endJob(.transcription, .meeting(id))
        #expect(store.beginJob(.transcription, .meeting(id), progress: "Preparing again"))
        store.setJobProgress(
            .transcription, .meeting(id), "Old result", details: .init(phase: "Old result", completed: 10, total: 10),
            attemptID: oldAttempt)
        try await Task.sleep(for: .milliseconds(550))
        #expect(store.backgroundJobs.first?.progress == "Preparing again")
        #expect(store.backgroundJobs.first?.progressDetails?.fractionCompleted == nil)
    }

    @Test func oldTaskRecordsDecodeWithoutProgressDetails() throws {
        let record = ManagedTaskRecord(kind: .transcription, meetingID: UUID(), meetingTitle: "Example recording")
        let data = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "progressDetails")
        let decoded = try JSONDecoder().decode(
            ManagedTaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.progressDetails == nil)
    }

    @MainActor @Test func stoppedTasksClearEstimates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var task = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Example recording", state: .paused, isPreview: true)
        task.progressDetails = TaskProgress(phase: "Generating", estimatedRemainingSeconds: 60)
        #expect(await store.saveManagedTask(task))
        #expect(store.managedTask(id: task.id)?.progressDetails == nil)
    }
    @MainActor @Test func historyPagingKeepsLiveProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        try store.managedTaskJournal.prepare()
        let task = ManagedTaskRecord(
            kind: .transcription, meetingID: UUID(), meetingTitle: "Example recording", state: .running)
        #expect(await store.saveManagedTask(task))
        store.recordManagedTaskProgress(
            task.key, progress: "Transcribing", details: TaskProgress(phase: "Transcribing", completed: 5, total: 10))
        let page = await store.taskHistoryPage(scope: .all)
        let row = try #require(page.first)
        guard case .managed(let current) = row else {
            Issue.record("Expected a managed task")
            return
        }
        #expect(current.progressDetails?.fractionCompleted == 0.5)
    }

    @MainActor @Test func historyPagingDoesNotRestoreRunningRowsAfterCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        try store.managedTaskJournal.prepare()
        var task = ManagedTaskRecord(
            kind: .transcription, meetingID: UUID(), meetingTitle: "Example recording", state: .running)
        #expect(await store.saveManagedTask(task))
        // Model a read whose persisted snapshot predates the current transition.
        task.state = .completed
        task.progressDetails = nil
        store.cacheManagedTask(task)
        #expect(await store.taskHistoryPage(scope: .active).isEmpty)
        let page = await store.taskHistoryPage(scope: .all)
        guard case .managed(let current) = try #require(page.first) else {
            Issue.record("Expected a managed task")
            return
        }
        #expect(current.state == .completed)
        #expect(current.progressDetails == nil)
    }

    @MainActor @Test func checkpointWriteKeepsProgressReportedDuringIO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        try store.managedTaskJournal.prepare()
        let task = ManagedTaskRecord(
            kind: .transcription, meetingID: UUID(), meetingTitle: "Example recording", state: .running)
        #expect(await store.saveManagedTask(task))
        store.managedTaskIO = ManagedTaskIO(beforeOperation: {
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor in
                store.recordManagedTaskProgress(
                    task.key, progress: "Transcribing",
                    details: TaskProgress(phase: "Transcribing", completed: 7, total: 10))
                delivered.signal()
            }
            guard delivered.wait(timeout: .now() + 5) == .success else {
                throw ServiceError("The synthetic progress update did not finish.")
            }
        })
        #expect(await store.saveManagedTask(task))
        #expect(store.managedTask(id: task.id)?.progressDetails?.fractionCompleted == 0.7)
    }

}
