import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingSearchAlertTests {
    @Test(arguments: ["recording", "finalizing"])
    func savedContentChangesDeferIndexingWithoutAttention(phase: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let id = await store.createMeeting(title: "Synthetic recording")
        store.recordingID = phase == "recording" ? id : nil
        store.isFinalizingRecording = phase == "finalizing"
        defer {
            store.recordingID = nil
            store.isFinalizingRecording = false
        }
        let task = ManagedTaskRecord(
            kind: .searchIndex, meetingID: id, meetingTitle: "Synthetic recording",
            searchIndexRevision: "saved-source", isAutomatic: true)
        #expect(await store.saveManagedTask(task))
        var meeting = try #require(store.meetings.first { $0.id == id })
        for index in 0..<3 {
            meeting.notes = "Saved note \(index)"
            #expect(await store.updateMeeting(meeting))
            store.scheduleSearchIndexing()
        }
        await store.reloadExternalManagedTasks()
        #expect(store.localSearch.deferredRecordingChanges)
        #expect(store.localSearch.scanTask == nil)
        #expect(store.managedTaskOperations.isEmpty)
        #expect(store.managedTask(id: task.id)?.state == .queued)
        #expect(store.taskAttentionCount == 0)
        #expect(!store.managedTaskJournal.hasExternalChanges)
    }

    @Test(arguments: [ManagedTaskState.queued, .running])
    func externalRequestChangesStillRequireReviewDuringRecording(state: ManagedTaskState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.flushManagedTaskCommands()
        let id = await store.createMeeting(title: "Synthetic recording")
        store.recordingID = id
        defer { store.recordingID = nil }
        var task = ManagedTaskRecord(
            kind: .searchIndex, meetingID: id, meetingTitle: "Synthetic recording",
            searchIndexRevision: "original-source", state: state, isAutomatic: true)
        #expect(await store.saveManagedTask(task))
        task.searchIndexRevision = "external-source"
        let external = ManagedTaskJournal(
            url: root.appendingPathComponent("tasks.jsonl"),
            indexURL: root.appendingPathComponent("external.sqlite"))
        try external.upsert(task)
        await store.reloadExternalManagedTasks()
        let saved = try #require(store.managedTask(id: task.id))
        #expect(saved.state == .paused)
        #expect(saved.recovery == .manual)
        #expect(saved.attentionReason == .externalChange)
        #expect(saved.errorMessage == "The saved task request changed outside this app. Resume to continue.")
        #expect(store.managedTaskOperations.isEmpty)
    }
}
