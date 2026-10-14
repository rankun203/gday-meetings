import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SummaryHistoryTests {
    @Test func generationsPreserveEditsAndLateResultsWithoutReplacingNewerSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Planning")
        var meeting = try #require(store.meeting(id: id))
        meeting.summary = "Existing text"
        meeting.notes = "Original notes"
        #expect(await store.updateMeeting(meeting))
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.model = "fixture-model"
        provider.apiKey = "fixture-secret"
        let taskID = UUID()
        let first = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: taskID, provider: provider,
            messages: [.init(role: "user", content: "Original request")], bodies: [], filePaths: [], extractTodos: false
        )
        let retry = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: taskID, provider: provider,
            messages: [.init(role: "user", content: "Changed request")], bodies: [], filePaths: [], extractTodos: true)
        #expect(retry.id == first.id)
        #expect(retry.messages.first?.content == "Original request")
        #expect(!retry.extractTodos)
        let second = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: UUID(), provider: provider,
            messages: [.init(role: "user", content: "Second request")], bodies: [], filePaths: [], extractTodos: false)
        meeting = try #require(store.meeting(id: id))
        meeting.notes = "Edited notes"
        #expect(await store.updateMeeting(meeting))
        try await store.commitSummaryGeneration(second, result: "Newer result", meetingID: id)
        try await store.commitSummaryGeneration(first, result: "Older result", meetingID: id)
        try await store.commitSummaryGeneration(first, result: "Duplicate result", meetingID: id)
        let folder = store.directory(for: id)
        let history = try SummaryHistory.read(at: folder)
        #expect(history.currentID == second.id)
        #expect(history.entries.count == 3)
        #expect(store.meeting(id: id)?.summary == "Newer result")
        #expect(store.meeting(id: id)?.notes == "Edited notes")
        let saved = try SummaryHistory.generation(taskID: taskID, at: folder)
        #expect(saved?.result == "Older result")
        let outputs = try history.entries.map { try SummaryGeneration.read(id: $0.id, at: folder).result }
        #expect(outputs.contains("Existing text"))
        let bytes = try #require(try SummaryHistory.bytes(SummaryGeneration.filename(first.id), at: folder))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("fixture-secret"))
    }

    @Test func restoringHistoryPreservesEditedSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Review")
        let request = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: UUID(), provider: ServiceProvider(kind: .openAICompatible),
            messages: [], bodies: [], filePaths: [], extractTodos: false)
        try await store.commitSummaryGeneration(request, result: "Generated text", meetingID: id)
        var edited = try #require(store.meeting(id: id))
        edited.summary = "Edited text"
        #expect(await store.updateMeeting(edited))
        #expect(await store.restoreSummaryGeneration(id: request.id, meetingID: id))
        #expect(store.meeting(id: id)?.summary == "Generated text")
        let history = try SummaryHistory.read(at: store.directory(for: id))
        let preserved = try #require(history.entries.first { $0.providerName == "Edited Summary" })
        #expect(try SummaryGeneration.read(id: preserved.id, at: store.directory(for: id)).result == "Edited text")
        #expect(await store.restoreSummaryGeneration(id: preserved.id, meetingID: id))
        #expect(store.meeting(id: id)?.summary == "Edited text")
    }

    @Test func committedResultRecoversWithoutProviderConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Review")
        let task = ManagedTaskRecord(kind: .summary, meetingID: id, meetingTitle: "Review", state: .running)
        let request = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: task.id, provider: ServiceProvider(kind: .openAICompatible),
            messages: [], bodies: [], filePaths: [], extractTodos: false)
        try await store.commitSummaryGeneration(request, result: "Saved result", meetingID: id)
        store.managedTasks = [task]
        store.managedTaskOperations[task.id] = Task {}
        defer { store.managedTaskOperations.removeValue(forKey: task.id) }
        store.settings.serviceProviders = []
        store.settings.summaryProviderID = nil
        try await store.performSummary(id: id, providerID: nil)
        #expect(store.meeting(id: id)?.summary == "Saved result")
    }

    @Test func endpointProvenanceOmitsCredentialsAndDetectsAddressChanges() {
        let endpoint = "https://fixture-user:fixture-password@example.test/v1?token=fixture-token"
        #expect(SummaryGeneration.endpointDescription(endpoint) == "https://example.test/v1")
        #expect(
            SummaryGeneration.endpointFingerprint(endpoint)
                != SummaryGeneration.endpointFingerprint("https://example.test/v2"))
    }

    @Test func admissionOrderWinsWithIdenticalTimestampsAndReversedWorkerOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Review")
        let provider = ServiceProvider(kind: .openAICompatible)
        let accepted = Date(timeIntervalSince1970: 100)
        let olderTask = ManagedTaskRecord(kind: .summary, meetingID: id, meetingTitle: "Review", createdAt: accepted)
        let newerTask = ManagedTaskRecord(kind: .summary, meetingID: id, meetingTitle: "Review", createdAt: accepted)
        try await store.reserveSummaryGeneration(task: olderTask)
        try await store.reserveSummaryGeneration(task: newerTask)
        #expect(try SummaryHistory.generation(taskID: olderTask.id, at: store.directory(for: id)) == nil)
        let newer = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: newerTask.id, provider: provider, messages: [], bodies: [], filePaths: [],
            extractTodos: false, acceptedAt: accepted)
        let older = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: olderTask.id, provider: provider, messages: [], bodies: [], filePaths: [],
            extractTodos: false, acceptedAt: accepted)
        #expect(older.generation < newer.generation)
        try await store.commitSummaryGeneration(newer, result: "Newer accepted request", meetingID: id)
        try await store.commitSummaryGeneration(older, result: "Older accepted request", meetingID: id)
        #expect(store.meeting(id: id)?.summary == "Newer accepted request")
        #expect(try store.hasCompletedSummary(taskID: newerTask.id, meetingID: id))
        #expect(try store.hasCompletedSummary(taskID: olderTask.id, meetingID: id))
    }

    @Test(arguments: [false, true]) func missingPreparedArtifactNeverBecomesANewRequest(completed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Review")
        let taskID = UUID()
        let request = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: taskID, provider: ServiceProvider(kind: .openAICompatible),
            messages: [.init(role: "user", content: "Saved input")], bodies: [], filePaths: [], extractTodos: false)
        if completed { try await store.commitSummaryGeneration(request, result: "Saved output", meetingID: id) }
        let folder = store.directory(for: id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SummaryGeneration.filename(request.id)))
        #expect(throws: (any Error).self) { try SummaryHistory.generation(taskID: taskID, at: folder) }
        do {
            _ = try await store.prepareSummaryGeneration(
                meetingID: id, taskID: taskID, provider: ServiceProvider(kind: .openAICompatible),
                messages: [.init(role: "user", content: "Replacement input")], bodies: [], filePaths: [],
                extractTodos: false)
            Issue.record("Missing immutable requests must not be replaced")
        }
        catch {}
        #expect(try SummaryHistory.bytes(SummaryGeneration.filename(request.id), at: folder) == nil)
    }

    @Test func failedCommitLeavesCurrentSummaryAndHistoryUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Review")
        let request = try await store.prepareSummaryGeneration(
            meetingID: id, taskID: UUID(), provider: ServiceProvider(kind: .openAICompatible),
            messages: [], bodies: [], filePaths: [], extractTodos: false)
        store.canonicalWriteHook = { throw ServiceError("Fixture write failure") }
        do {
            try await store.commitSummaryGeneration(request, result: "Unsaved result", meetingID: id)
            Issue.record("The commit should fail")
        }
        catch {}
        #expect(store.meeting(id: id)?.summary == "")
        let saved = try SummaryGeneration.read(id: request.id, at: store.directory(for: id))
        #expect(saved.result == nil)
        #expect(try SummaryHistory.read(at: store.directory(for: id)).currentID == nil)
    }
}
