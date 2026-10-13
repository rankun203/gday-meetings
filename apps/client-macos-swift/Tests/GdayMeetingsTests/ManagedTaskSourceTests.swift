import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ManagedTaskSourceTests {
    @Test func committedSourceIgnoresSpeakerAssignmentsAndUnrelatedMetadata() {
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.transcript = [.init(text: "First sentence."), .init(text: "Second sentence.")]
        let receipt = UUID()
        meeting.transcriptSource = .init(id: receipt, providerName: "Fixture", generatedAt: Date())
        let original = MeetingStore.automaticTaskSource(meeting, kind: .summary)
        meeting.title = "Renamed meeting"
        meeting.transcript[0].speaker = "Speaker 2"
        meeting.transcript[0].personID = UUID()
        meeting.chat = [.init(content: "Synthetic chat")]
        #expect(MeetingStore.automaticTaskSource(meeting, kind: .summary) == original)
        meeting.notes = "New notes"
        #expect(MeetingStore.automaticTaskSource(meeting, kind: .summary) != original)
        meeting.notes = ""
        meeting.transcriptSource?.id = UUID()
        #expect(MeetingStore.automaticTaskSource(meeting, kind: .summary) != original)
        meeting.transcriptSource?.id = receipt
        meeting.transcript[0].text = "Changed sentence."
        #expect(MeetingStore.automaticTaskSource(meeting, kind: .summary) != original)
    }

    @Test func automaticAdmissionReusesCompletedSourceAcrossReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.transcript = [.init(text: "Committed words")]
        try await store.insertImportedMeeting(meeting)
        var completed = ManagedTaskRecord(kind: .summary, meetingID: meeting.id, meetingTitle: meeting.title)
        completed.sourceRevision = MeetingStore.automaticTaskSource(meeting, kind: .summary)
        completed.state = .completed
        completed.isAutomatic = true
        let saved = completed
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(saved) }
        try await store.restoreManagedTasks()
        #expect(await store.queueSummary(id: meeting.id, automatically: true) == saved.id)
        #expect(await store.queueSummary(id: meeting.id, automatically: true) == saved.id)
        let records = try await store.managedTaskIO.perform { try journal.query(limit: 10) }
        #expect(records.count == 1)
        #expect(records.first?.state == .completed)
    }

    @Test func newCommittedTranscriptSupersedesOnlyItsSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.transcript = [.init(text: "First committed result")]
        try await store.insertImportedMeeting(meeting)
        let other = ManagedTaskRecord(kind: .diarization, meetingID: meeting.id, meetingTitle: meeting.title)
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(other) }
        try await store.restoreManagedTasks()
        let first = try #require(await store.queueSummary(id: meeting.id, automatically: true))
        let oldRevision = store.managedTask(id: first)?.sourceRevision
        meeting.transcript = [.init(text: "New committed result")]
        #expect(await store.updateMeeting(meeting))
        let replacement = try #require(await store.queueSummary(id: meeting.id, automatically: true))
        #expect(store.managedTask(id: replacement)?.state == .queued)
        #expect(store.managedTask(id: replacement)?.sourceRevision != oldRevision)
        #expect(store.managedTask(id: replacement)?.userStopped == false)
        #expect(
            store.managedTasks.filter { $0.meetingID == meeting.id && $0.kind == .summary && $0.state.isActive }.count
                == 1)
        #expect(store.managedTask(id: other.id) == other)
        #expect(store.managedTask(id: replacement)?.timeline?.contains { $0.kind == .ended } == true)
    }

    @Test func explicitSummaryChangesSupersedeWhileIdenticalRequestsStayDeduplicated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        store.settings.autoSummarize = true
        var meeting = Meeting(title: "Synthetic summary meeting")
        meeting.transcript = [.init(text: "Committed transcript")]
        try await store.insertImportedMeeting(meeting)
        let provider = UUID()
        let first = try #require(
            await store.queueSummary(id: meeting.id, providerID: provider, instructions: "First request"))
        #expect(await store.queueSummary(id: meeting.id, providerID: provider, instructions: " First request ") == nil)
        store.scheduleAutomaticSummary(id: meeting.id)
        let replacement = try #require(
            await store.queueSummary(id: meeting.id, providerID: provider, instructions: "New request"))
        #expect(store.managedTask(id: replacement)?.summaryInstructions == "New request")
        #expect(store.managedTask(id: replacement)?.isAutomatic == false)
        #expect(store.managedTask(id: replacement)?.timeline?.contains { $0.kind == .ended } == true)
        #expect(store.managedTask(id: first)?.state != .running)
        let otherProvider = UUID()
        let changedProvider = try #require(
            await store.queueSummary(id: meeting.id, providerID: otherProvider, instructions: "New request"))
        #expect(store.managedTask(id: changedProvider)?.providerID == otherProvider)
        #expect(store.managedTask(id: changedProvider)?.summaryInstructions == "New request")
        #expect(store.managedTasks.filter { $0.kind == .summary && $0.state.isActive }.count == 1)
    }

    @Test func searchSupersedesQueuedRevisionAndBatchCancellationKeepsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        let provider = ServiceProvider(kind: .localSearch)
        store.settings.serviceProviders = [provider]
        store.settings.searchProviderID = provider.id
        let meetingID = await store.createMeeting(title: "Synthetic search meeting")
        var request = SearchIndexRebuild()
        request.meetings = [meetingID]
        try store.localSearch.saveRebuild(request)
        let batch = request.id
        let first = try #require(
            await store.queueSearchIndex(id: meetingID, revision: "one", force: true, batchID: batch))
        #expect(await store.queueSearchIndex(id: meetingID, revision: "one") == first)
        #expect(await store.queueSearchIndex(id: meetingID, revision: "two", force: true, batchID: batch) == nil)
        #expect(store.managedTask(id: first)?.state == .cancelled)
        #expect(store.managedTask(id: first)?.userStopped == false)
        let replacement = try #require(
            await store.queueSearchIndex(id: meetingID, revision: "two", force: true, batchID: batch))
        #expect(store.managedTask(id: replacement)?.searchIndexRevision == "two")
        #expect(await store.cancelManagedTaskBatch(batch))
        let records = try await store.managedTasksForBatch(batch)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.state == .cancelled && $0.userStopped })
        #expect(records.contains { $0.id == replacement })
    }
    @Test func cancelledRebuildRejectsLateAdmissionAndCancelsQueuedChildrenOnRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        let provider = ServiceProvider(kind: .localSearch)
        store.settings.serviceProviders = [provider]
        store.settings.searchProviderID = provider.id
        let id = await store.createMeeting(title: "Synthetic recovery meeting")
        var request = SearchIndexRebuild()
        request.meetings = [id]
        try store.localSearch.saveRebuild(request)
        let child = try #require(
            await store.queueSearchIndex(id: id, revision: "source", force: true, batchID: request.id))
        // Simulate termination after the durable cancel marker but before child cancellation.
        request.state = .cancelled
        try store.localSearch.saveRebuild(request)
        #expect(await store.queueSearchIndex(id: id, revision: "new source", force: true, batchID: request.id) == nil)
        store.isSchedulingManagedTasks = false
        await store.recoverUnfinishedManagedTasks()
        #expect(store.managedTask(id: child)?.state == .cancelled)
        #expect(store.managedTask(id: child)?.userStopped == true)
        #expect(!store.isJobRunning(.searchIndex, .meeting(id)))
    }

    @Test func newRebuildCannotAdoptAStoppingChildFromThePreviousBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.managedTaskPreparation?.value
        store.isSchedulingManagedTasks = true
        let provider = ServiceProvider(kind: .localSearch)
        store.settings.serviceProviders = [provider]
        store.settings.searchProviderID = provider.id
        let meetingID = await store.createMeeting(title: "Synthetic stopping task")
        let oldBatch = UUID()
        var child = ManagedTaskRecord(kind: .searchIndex, meetingID: meetingID, meetingTitle: "Synthetic stopping task")
        child.searchIndexRevision = "source"
        child.batchID = oldBatch
        child.state = .running
        child.userStopped = true
        let stopping = child
        let journal = store.managedTaskJournal
        try await store.managedTaskIO.perform { try journal.upsert(stopping) }
        try await store.restoreManagedTasks()
        var replacement = SearchIndexRebuild()
        replacement.meetings = [meetingID]
        try store.localSearch.saveRebuild(replacement)
        #expect(
            await store.queueSearchIndex(id: meetingID, revision: "source", force: true, batchID: replacement.id) == nil
        )
        #expect(store.managedTask(id: child.id)?.batchID == oldBatch)
        #expect(store.managedTask(id: child.id)?.userStopped == true)
        #expect(try await store.managedTasksForBatch(replacement.id).isEmpty)
    }

}
