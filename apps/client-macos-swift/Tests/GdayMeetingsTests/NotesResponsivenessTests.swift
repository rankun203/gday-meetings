import AppKit
import Combine
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct NotesResponsivenessTests {
    @Test func rapidEditsPublishOnlyTheSelectedDraftAndSnapshotsStayCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic notes")
        let original = try #require(store.meeting(id: id))
        let draft = store.notesStorage.draft(id, fallback: original.notes)
        var storeUpdates = 0
        var draftUpdates = 0
        let storeSubscription = store.objectWillChange.sink { storeUpdates += 1 }
        let draftSubscription = draft.objectWillChange.sink { draftUpdates += 1 }
        let longNotes = String(repeating: "Synthetic line with a timestamp. <!-- gday:t=1:00:00 -->\n", count: 250)
        for index in 0..<200 { store.editNotes(id: id, text: longNotes + "Edit \(index)") }
        #expect(storeUpdates == 0)
        #expect(draftUpdates == 200)
        #expect(store.meetings.first(where: { $0.id == id })?.notes == original.notes)
        #expect(store.meeting(id: id)?.notes == longNotes + "Edit 199")
        // Autosave does not broadcast the library either, and a durable draft
        // remains authoritative until an explicit editing boundary publishes it.
        try await store.notesStorage.flush(id)
        #expect(storeUpdates == 0)
        #expect(store.meeting(id: id)?.notes == longNotes + "Edit 199")
        #expect(await store.flushNotes())
        #expect(store.meetings.first(where: { $0.id == id })?.notes == longNotes + "Edit 199")
        withExtendedLifetime((storeSubscription, draftSubscription)) {}
    }

    @Test func unchangedRepresentableUpdateDoesNotRequestLayoutOrResetUndo() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        let text = NotesTextView(usingTextLayoutManager: true)
        let editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "Synthetic notes", editable: true, clock: { nil },
            canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {})
        text.load(editor.markdown)
        text.isEditable = true
        text.setSelectedRange(NSRange(location: 3, length: 0))
        text.frame = window.contentView!.bounds
        window.contentView = text
        text.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        text.needsLayout = false
        #expect(!text.needsLayout)
        for _ in 0..<200 { editor.update(text) }
        #expect(!text.needsLayout)
        #expect(text.selectedRange() == NSRange(location: 3, length: 0))
        #expect(text.string == "Synthetic notes")
    }

    @Test func markedTextSurvivesUnrelatedRepresentableUpdates() {
        let text = NotesTextView(usingTextLayoutManager: true)
        let editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { nil },
            canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {})
        text.editor = editor
        text.load("")
        text.isEditable = true
        text.delegate = text
        text.textStorage?.delegate = text
        text.setMarkedText(
            "拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(text.hasMarkedText())
        editor.update(text)
        #expect(text.hasMarkedText())
        #expect(text.string == "拼音")
        text.unmarkText()
        #expect(!text.hasMarkedText())
        #expect(text.string == "拼音")
    }
}

extension NotesResponsivenessTests {
    @Test func imagePreparationDoesNotReplaceAChangedDocumentOrGetCancelledByNormalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = NotesImageTests()
        let original = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: root)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {}, directory: root)
        text.isEditable = true
        text.delegate = text
        text.load("![Diagram](\(original))")
        let reference = try #require(NotesImageReference.parse(in: text.string).first)
        text.resizeImage(reference, width: 80)
        // A scheduled normalization must not cancel the user's resize.
        text.normalizeImageWidths()
        await text.waitForImagePreparation()
        #expect(text.string.contains("width=\"80\""))
        let resized = try #require(NotesImageReference.parse(in: text.string).first)
        text.resizeImage(resized, width: 90)
        text.load("New document")
        await text.waitForImagePreparation()
        #expect(text.string == "New document")
    }
}

extension NotesResponsivenessTests {
    @Test func pendingImageResultSurvivesCleanupUntilPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Existing notes".utf8).write(to: root.appendingPathComponent("notes.md"))
        let worker = NotesImagePreparation()
        let lease = UUID()
        await worker.retainResults(lease, directory: root)
        let result = try await worker.importImages(urls: [], bytes: NotesImageTests().png(), directory: root)
        let image = try #require(result.first)
        let original = try NotesAssets.safeURL(relativePath: image.originalPath, directory: root)
        try await worker.cleanupSavedIfMatching("Existing notes", directory: root)
        #expect(FileManager.default.fileExists(atPath: original.path))
        let resized = try await worker.resize(image, width: 80, source: image.markdown, directory: root)
        let preview = try NotesAssets.safeURL(relativePath: resized.displayPath, directory: root)
        try await worker.cleanupPreviews("Existing notes", directory: root)
        #expect(FileManager.default.fileExists(atPath: preview.path))
        // Once consumed or canceled, the lease releases without preventing later cleanup.
        await worker.releaseResults(lease)
        try await worker.cleanupPreviews("Existing notes", directory: root)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}

extension NotesResponsivenessTests {
    @Test func obsoleteThumbnailRequestDoesNotDecorateReplacementDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(NotesImageTests().png(), filename: "diagram.png", directory: root)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {}, directory: root)
        text.load("![Old diagram](\(path))")
        text.prepareImageLayout()
        text.load("![Current diagram](\(path))")
        text.prepareImageLayout()
        await text.images.waitForPreparation()
        #expect(text.images.views.count == 1)
        #expect(text.images.views.first?.reference.alt == "Current diagram")
        let references = NotesImageReference.parse(in: text.string)
        let worker = NotesImagePreparation()
        let canceled = Task { await worker.prepare(references, width: 300, directory: root) }
        canceled.cancel()
        #expect(await canceled.value.isEmpty)
    }
}
