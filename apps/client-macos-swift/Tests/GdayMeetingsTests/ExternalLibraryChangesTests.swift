import Foundation
import Testing

@testable import GdayMeetings

@Suite struct ExternalLibraryChangesTests {
    @Test func pathsScopeCatalogReadsAndKeepAncestorRecovery() {
        let root = URL(fileURLWithPath: "/tmp/synthetic-library")
        #expect(
            ExternalLibraryChanges(
                paths: [root.appendingPathComponent("meetings/example/summary.md")], root: root, rebuild: false)
                == .meetings)
        #expect(
            ExternalLibraryChanges(
                paths: [root.appendingPathComponent("people/person.json")], root: root, rebuild: false) == .people)
        #expect(
            ExternalLibraryChanges(paths: [root.appendingPathComponent("tags")], root: root, rebuild: false) == .tags)
        #expect(
            ExternalLibraryChanges(
                paths: [root.appendingPathComponent("tasks-index.sqlite-wal")], root: root, rebuild: false
            ).isEmpty)
        #expect(ExternalLibraryChanges(paths: [root], root: root, rebuild: false) == .all)
        #expect(ExternalLibraryChanges(paths: [], root: root, rebuild: true) == .all)
    }

    @MainActor @Test func meetingChangesDoNotReadUnrelatedCatalogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        let id = store.createMeeting(title: "Original title")
        var meeting = try #require(store.meeting(id: id))
        meeting.title = "External title"
        try MeetingFolderStorage.write(meeting, directory: root)
        let tags = root.appendingPathComponent("tags")
        try FileManager.default.createDirectory(at: tags, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: tags.appendingPathComponent(UUID().uuidString + ".json"))
        store.requestExternalLibraryReload(
            paths: [LibraryFileMonitor.canonicalRoot(store.directory(for: id)).appendingPathComponent("metadata.json")],
            rebuild: false)
        let finished = try await waitForMainActorTestCondition(timeout: .seconds(3)) {
            store.meeting(id: id)?.title == "External title"
        }
        #expect(finished)
        #expect(store.libraryDataStatus.error == nil)
    }

    @MainActor @Test func catalogRefreshWaitsForTransactionAndPreservesDirtyEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        let person = Person(name: "External person")
        let peopleDirectory = root.appendingPathComponent("people")
        try FileManager.default.createDirectory(at: peopleDirectory, withIntermediateDirectories: true)
        let path = peopleDirectory.appendingPathComponent(person.id.uuidString + ".json")
        try JSONEncoder().encode(person).write(to: path)
        let transaction = root.appendingPathComponent(".document-transaction")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        store.requestExternalLibraryReload(paths: [path], rebuild: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.people.isEmpty)
        try FileManager.default.removeItem(at: transaction)
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(3)) { store.people == [person] }
        #expect(loaded)
        store.people[0].name = "Unsaved name"
        var external = person
        external.name = "Changed externally"
        try JSONEncoder().encode(external).write(to: path)
        store.requestExternalLibraryReload(paths: [path], rebuild: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.people[0].name == "Unsaved name")
        #expect(try JSONDecoder().decode(Person.self, from: Data(contentsOf: path)).name == "Changed externally")
    }

    @MainActor @Test func malformedCatalogDoesNotBlockIndependentRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        let id = store.createMeeting(title: "Original title")
        var meeting = try #require(store.meeting(id: id))
        meeting.title = "External title"
        try MeetingFolderStorage.write(meeting, directory: root)
        let task = ManagedTaskRecord(
            kind: .summary, meetingID: id, meetingTitle: "External history", state: .completed)
        let external = ManagedTaskJournal(
            url: store.managedTaskJournal.url, indexURL: root.appendingPathComponent("external.sqlite"))
        try external.upsert(task)
        let tags = root.appendingPathComponent("tags")
        try FileManager.default.createDirectory(at: tags, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: tags.appendingPathComponent(UUID().uuidString + ".json"))

        store.requestExternalLibraryReload(paths: [root], rebuild: true)
        let refreshed = try await waitForMainActorTestCondition(timeout: .seconds(3)) {
            store.meeting(id: id)?.title == "External title" && store.managedTasks.contains { $0.id == task.id }
        }
        #expect(refreshed)
        #expect(store.libraryDataStatus.error != nil)
        #expect(store.tags.isEmpty)
        #expect(store.managedTaskOperations.isEmpty)
    }
}
