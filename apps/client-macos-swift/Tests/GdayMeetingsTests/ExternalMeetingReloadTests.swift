import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ExternalMeetingReloadTests {
    @Test func scopedEventReadsOnlyItsMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let first = await store.createMeeting(title: "First")
        _ = await store.createMeeting(title: "Second")
        var external = try #require(store.meetings.first { $0.id == first })
        external.title = "External revision"
        try MeetingFolderStorage.write(external, directory: root)
        let gate = ReloadReadGate(blocks: false)
        store.externalMeetingReader = { id, root in
            let meeting = try MeetingFolderStorage.read(id: id, directory: root)
            gate.arrive(id)
            return meeting
        }
        store.requestExternalLibraryReload(
            paths: [store.directory(for: first).appendingPathComponent("summary.md")], rebuild: false)
        #expect(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.meetings.first { $0.id == first }?.title == "External revision"
            })
        #expect(gate.ids == [first])
        #expect(!gate.wasMainThread)
    }

    @Test(arguments: ["edit", "delete", "generation", "save-admission", "notes"])
    func slowReadCannotReplaceNewerLocalState(_ change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Original")
        var external = try #require(store.meetings.first { $0.id == id })
        external.title = "External revision"
        try MeetingFolderStorage.write(external, directory: root)
        let gate = ReloadReadGate()
        defer { gate.release() }
        store.externalMeetingReader = { id, root in
            let value = try MeetingFolderStorage.read(id: id, directory: root)
            gate.arrive(id)
            return value
        }
        let reload = Task { await store.reloadExternalLibraryDocuments(reloadCatalogs: false) }
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(3)) { !gate.ids.isEmpty })
        // Reaching this main-actor code while storage is blocked is the responsiveness assertion.
        #expect(!gate.wasMainThread)
        switch change {
        case "edit":
            store.meetings[0].title = "Temporary edit"
            store.meetings[0].title = "Original"  // Equality alone misses this ABA edit.
        case "delete": store.meetings.removeAll { $0.id == id }
        case "generation": store.externalReloadGeneration = UUID()
        case "save-admission": store.invalidateExternalMeetingReloads(ids: [id])
        default: store.notesStorage.schedule(id, text: "Unsaved notes")
        }
        gate.release()
        _ = await reload.value
        #expect(store.meetings.first { $0.id == id }?.title != "External revision")
        #expect(try MeetingFolderStorage.read(id: id, directory: root).title == "External revision")
    }

    @Test func batchUnionRetainsScopedIDsAndAncestorRecovery() {
        let root = URL(fileURLWithPath: "/tmp/synthetic-reload")
        let first = UUID()
        let second = UUID()
        var batch = ExternalLibraryChangeBatch(
            paths: [root.appendingPathComponent("meetings/" + MeetingIdentity.string(first) + "/summary.md")],
            root: root)
        batch.formUnion(
            .init(
                paths: [
                    root.appendingPathComponent(
                        "meetings/" + MeetingFolderLocation.name(id: second, date: Date()) + "/content.json")
                ], root: root))
        #expect(batch.meetingIDs == [first, second])
        batch.formUnion(.init(paths: [root.appendingPathComponent("meetings")], root: root))
        #expect(batch.meetingIDs == nil)
    }
}

private final class ReloadReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blocks: Bool
    private var readIDs: [UUID] = []
    private var mainThread = false
    init(blocks: Bool = true) { self.blocks = blocks }
    var ids: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return readIDs
    }
    var wasMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThread
    }
    func arrive(_ id: UUID) {
        lock.lock()
        readIDs.append(id)
        mainThread = mainThread || Thread.isMainThread
        lock.unlock()
        if blocks { _ = semaphore.wait(timeout: .now() + 5) }
    }
    func release() { semaphore.signal() }
}
