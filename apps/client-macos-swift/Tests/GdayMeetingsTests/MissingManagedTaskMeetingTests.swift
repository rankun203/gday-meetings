import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MissingManagedTaskMeetingTests {
    @Test func schedulerLeavesDeletingMeetingQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Deleting meeting")
        let task = ManagedTaskRecord(kind: .summary, meetingID: id, meetingTitle: "Deleting meeting")
        try store.managedTaskJournal.upsert(task)
        store.deletingMeetingIDs.insert(id)
        await store.managedTaskCommands.run { await store.startManagedTasks() }
        #expect(store.managedTaskJournal.record(id: task.id)?.state == .queued)
        #expect(store.managedTaskOperations[task.id] == nil)
        #expect(!store.backgroundJobs.contains { $0.meetingID == id })
        await store.cancelTasksForDeletedMeeting(id)
        #expect(store.managedTaskJournal.record(id: task.id)?.state == .cancelled)
    }

    @Test(arguments: [false, true])
    func lateFailurePreservesTerminalCancellationUnlessResultCommitted(hasReceipt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Cancelled meeting task")
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: id, meetingTitle: "Cancelled meeting task", state: .running)
        try store.managedTaskJournal.upsert(task)
        store.cacheManagedTask(task)
        if hasReceipt {
            var meeting = try #require(store.meetings.first { $0.id == id })
            meeting.completedTaskIDs[task.kind.rawValue] = task.id
            #expect(await store.updateMeeting(meeting))
        }
        await store.cancelTasksForDeletedMeeting(id)
        let cancelled = try #require(store.managedTaskJournal.record(id: task.id))
        // Reproduce a stale worker/cache after the deletion command commits.
        store.cacheManagedTask(task)
        await store.completeManagedTask(
            task.id, state: .failed, recovery: .manual, message: "Couldn’t read this meeting.")
        let result = try #require(store.managedTaskJournal.record(id: task.id))
        #expect(result.state == (hasReceipt ? .completed : .cancelled))
        #expect(!result.needsAttention)
        if !hasReceipt { #expect(result == cancelled) }
    }

    @Test func missingMeetingBecomesHistoryAndStaysUnchangedOnWake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        let task = ManagedTaskRecord(
            kind: .diarization, meetingID: UUID(), meetingTitle: "Removed meeting",
            state: .failed, errorMessage: "This meeting no longer exists.", recovery: .blocked)
        try store.managedTaskJournal.upsert(task)
        await store.recoverUnfinishedManagedTasks()
        let cancelled = try #require(store.managedTask(id: task.id))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.recovery == .none)
        #expect(cancelled.errorMessage == "Meeting not found. No further processing will run.")
        #expect(!cancelled.needsAttention)
        #expect(!store.canRetryManagedTask(cancelled))
        let journal = try Data(contentsOf: store.managedTaskJournal.url)
        await store.retryManagedTask(id: task.id)
        await store.recoverUnfinishedManagedTasks()
        #expect(store.managedTask(id: task.id) == cancelled)
        #expect(try Data(contentsOf: store.managedTaskJournal.url) == journal)
    }

    @Test func unreadableOrUnavailableLibraryIsNotConfirmedMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Unreadable meeting")
        let folder = try MeetingFolderLocation.resolve(id: id, directory: root)
        try Data("invalid metadata".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        #expect(!(await store.managedTaskMeetingIsMissing(id)))
        let unavailable = root.appendingPathComponent("meetings")
        try FileManager.default.removeItem(at: unavailable)
        #expect(!(await store.managedTaskMeetingIsMissing(id)))
    }

    @Test(arguments: [false, true])
    func recoveryPreservesReadFailureInsteadOfCancelling(unavailable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Read failure")
        let folder = try MeetingFolderLocation.resolve(id: id, directory: root)
        if unavailable {
            try FileManager.default.removeItem(at: root.appendingPathComponent("meetings"))
        }
        else {
            try Data("invalid metadata".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        }
        store.meetings.removeAll { $0.id == id }
        let task = ManagedTaskRecord(kind: .diarization, meetingID: id, meetingTitle: "Read failure")
        try store.managedTaskJournal.upsert(task)
        await store.recoverUnfinishedManagedTasks()
        let recovered = try #require(store.managedTask(id: task.id))
        #expect(recovered.state == .failed)
        #expect(recovered.recovery == .manual)
        #expect(
            recovered.errorMessage == "Couldn’t read this meeting. Check that the library is available, then retry.")
        #expect(recovered.needsAttention)
    }

    @Test func ordinaryCancellationStillReconcilesCommittedReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Committed result")
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: id, meetingTitle: "Committed result",
            state: .cancelled, recovery: .manual)
        var meeting = try #require(store.meetings.first { $0.id == id })
        meeting.completedTaskIDs[task.kind.rawValue] = task.id
        #expect(await store.updateMeeting(meeting))
        try store.managedTaskJournal.upsert(task)
        await store.recoverUnfinishedManagedTasks()
        #expect(store.managedTask(id: task.id)?.state == .completed)
    }

    @Test func deletingMeetingRetainsQuietTaskRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        let id = await store.createMeeting(title: "Deleted meeting")
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: id, meetingTitle: "Deleted meeting",
            state: .failed, errorMessage: "Provider unavailable.", recovery: .manual)
        try store.managedTaskJournal.upsert(task)
        #expect(await store.deleteMeeting(id: id))
        let cancelled = try #require(store.managedTask(id: task.id))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.errorMessage == "Meeting was deleted.")
        #expect(!cancelled.needsAttention)
        #expect(!store.canRetryManagedTask(cancelled))
    }
}
