import Foundation
import Testing

@testable import GdayMeetings

private actor NotesBoundaryEncoder: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID = .granite97M
    private(set) var passages: [String] = []
    func prepare() {}
    func unload() {}
    func passageParts(_ text: String) -> [String] { [text] }
    func embed(_ text: String, isQuery: Bool) -> [Double] {
        if !isQuery { passages.append(text) }
        var vector = Array(repeating: 0.0, count: modelID.dimensions)
        vector[0] = 1
        return vector
    }
}

@MainActor struct NotesIndexingBoundaryTests {
    @Test func autosaveDoesNotAdmitIndexTaskUntilEditorExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Notes indexing fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        try LibraryIndex(directory: root).rebuild()
        let store = MeetingStore(dataDirectory: root)
        store.notesStorage.beginEditing(meeting.id)
        let encoder = NotesBoundaryEncoder()
        store.localSearch = LocalSearchController(
            directory: root, indexDirectory: store.indexDirectory,
            makeEncoder: { _, _ in encoder }, modelReady: { _ in true })
        var provider = ServiceProvider(kind: .localSearch)
        provider.enabledCapabilities = [.search]
        store.settings.serviceProviders = [provider]
        store.settings.searchProviderID = provider.id
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            !store.managedTasksLoading && !store.libraryDataStatus.isBuilding
        }
        #expect(loaded)
        #expect(await store.ensureMeetingLoaded(id: meeting.id))
        await store.openNotes(id: meeting.id)
        store.editNotes(id: meeting.id, text: "First draft")
        store.editNotes(id: meeting.id, text: "Final draft for indexing")
        let autosaved = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            store.notesStorage.pending[meeting.id] == nil
        }
        #expect(autosaved)
        #expect(
            try String(contentsOf: store.notesStorage.url(meeting.id), encoding: .utf8) == "Final draft for indexing")
        store.scheduleSearchIndexing()
        let scanned = try await waitForMainActorTestCondition(timeout: .seconds(8)) {
            store.localSearch.scanTask == nil
        }
        #expect(scanned)
        #expect(store.managedTasks.filter { $0.kind == .searchIndex }.isEmpty)
        #expect(await encoder.passages.isEmpty)

        await store.closeNotes(id: meeting.id)
        let indexed = try await waitForMainActorTestCondition(timeout: .seconds(12)) {
            store.managedTasks.contains { $0.kind == .searchIndex && $0.state == .completed }
        }
        #expect(indexed)
        #expect(await encoder.passages.contains { $0.contains("Final draft for indexing") })
        #expect(await store.finalizeForQuit())
    }

    @Test func quittingDuringNotesEditingIndexesSavedDraftOnNextLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Quit indexing fixture")
        try MeetingFolderStorage.write(meeting, directory: root)
        try LibraryIndex(directory: root).rebuild()
        let store = MeetingStore(dataDirectory: root)
        #expect(await store.ensureMeetingLoaded(id: meeting.id))
        await store.openNotes(id: meeting.id)
        store.editNotes(id: meeting.id, text: "Draft saved by quit")
        #expect(await store.finalizeForQuit())

        let restored = MeetingStore(dataDirectory: root)
        let encoder = NotesBoundaryEncoder()
        restored.localSearch = LocalSearchController(
            directory: root, indexDirectory: restored.indexDirectory,
            makeEncoder: { _, _ in encoder }, modelReady: { _ in true })
        var provider = ServiceProvider(kind: .localSearch)
        provider.enabledCapabilities = [.search]
        restored.settings.serviceProviders = [provider]
        restored.settings.searchProviderID = provider.id
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            !restored.managedTasksLoading && !restored.libraryDataStatus.isBuilding
        }
        #expect(loaded)
        #expect(!restored.notesStorage.isEditing(meeting.id))
        restored.searchConfigurationChanged()
        let indexed = try await waitForMainActorTestCondition(timeout: .seconds(12)) {
            restored.managedTasks.contains { $0.kind == .searchIndex && $0.state == .completed }
        }
        #expect(indexed)
        #expect(await encoder.passages.contains { $0.contains("Draft saved by quit") })
        #expect(await restored.finalizeForQuit())
    }

}
