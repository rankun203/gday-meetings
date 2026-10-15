import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct NotesViewModeTests {
    @Test func entryDefaultUsesRecordingState() {
        #expect(NotesViewMode(isRecordingOnEntry: false).reading)
        #expect(!NotesViewMode(isRecordingOnEntry: true).reading)
    }

    @Test func manualChoiceLastsForTheEntryAndReentryUsesFreshDefault() {
        var openNotes = NotesViewMode(isRecordingOnEntry: false)
        openNotes.reading = false
        #expect(!openNotes.reading)
        let reenteredNotes = NotesViewMode(isRecordingOnEntry: false)
        #expect(reenteredNotes.reading)
        var recordingNotes = NotesViewMode(isRecordingOnEntry: true)
        recordingNotes.reading = true
        #expect(recordingNotes.reading)
        #expect(!NotesViewMode(isRecordingOnEntry: true).reading)
    }

    @Test func readingOpensWithoutEditingBoundaryAndLoadsLatestDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic notes")
        store.editNotes(id: id, text: "- [ ] Synthetic task")
        await store.openNotes(id: id, editing: false)
        #expect(!store.notesStorage.isEditing(id))
        #expect(store.notesStorage.draft(id, fallback: "").text == "- [ ] Synthetic task")
        store.editNotes(id: id, text: "- [x] Synthetic task")
        #expect(store.notesStorage.draft(id, fallback: "").text == "- [x] Synthetic task")
        await store.closeNotes(id: id)
    }
}
