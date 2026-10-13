import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SearchIndexRebuildTests {
    @Test func requestAndCancellationSurviveControllerReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalSearchController(directory: root, indexDirectory: root)
        var request = SearchIndexRebuild()
        let meeting = UUID()
        request.meetings = [meeting]
        request.children[meeting] = UUID()
        request.state = .running
        try controller.saveRebuild(request)
        let resumed = LocalSearchController(directory: root, indexDirectory: root)
        #expect(resumed.rebuildRequest == request)
        request.state = .cancelled
        try resumed.saveRebuild(request)
        let cancelled = LocalSearchController(directory: root, indexDirectory: root)
        #expect(cancelled.rebuildRequest?.id == request.id)
        #expect(cancelled.rebuildRequest?.isActive == false)
        #expect(cancelled.rebuildRequest?.children == request.children)
        var early = SearchIndexRebuild()
        early.state = .cancelled
        #expect(early.progress == "Rebuild cancelled.")
    }

    @Test func rebuildProgressRecoversCompletedChildrenFromJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        let id = await store.createMeeting(title: "Synthetic rebuild meeting")
        var request = SearchIndexRebuild()
        request.meetings = [id]
        request.state = .running
        try store.localSearch.saveRebuild(request)
        var child = ManagedTaskRecord(kind: .searchIndex, meetingID: id, meetingTitle: "Synthetic rebuild meeting")
        child.batchID = request.id
        child.state = .completed
        let completed = child
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(completed) }
        try await store.refreshSearchIndexRebuild()
        #expect(store.localSearch.rebuildRequest?.state == .completed)
        #expect(store.localSearch.rebuildRequest?.finished == 1)
        #expect(store.localSearch.rebuildRequest?.children[id] == completed.id)
    }
    @Test func supersededChildWaitsForLatestRevisionInsteadOfCompletingRebuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        let id = await store.createMeeting(title: "Synthetic rebuild meeting")
        var child = ManagedTaskRecord(kind: .searchIndex, meetingID: id, meetingTitle: "Synthetic rebuild meeting")
        var request = SearchIndexRebuild()
        request.meetings = [id]
        request.children[id] = child.id
        request.state = .running
        child.batchID = request.id
        child.state = .cancelled
        child.userStopped = false
        try store.localSearch.saveRebuild(request)
        let superseded = child
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(superseded) }
        try await store.refreshSearchIndexRebuild()
        #expect(store.localSearch.rebuildRequest?.state == .running)
        #expect(store.localSearch.rebuildRequest?.finished == 0)
        #expect(store.localSearch.rebuildRequest?.children[id] == nil)
    }

}
