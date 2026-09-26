import AppKit
import Foundation
import Testing

@testable import GdayMeetings

struct NotesDocumentTests {
    @Test func validMarkersRoundTripAndDamagedCommentsRemain() {
        let source =
            "# Heading <!-- gday:t=3:05 -->\r\n\n- item <!-- gday:t=1:12:34.50 -->\n<!-- gday:t=9:30 -->\n```sql\nselect 1\n```\n<!-- ordinary -->\nBroken <!-- gday:t=3:99 -->"
        let document = NotesDocument(source)
        #expect(document.markdown == source)
        #expect(!document.text.contains("gday:t=3:05"))
        #expect(document.text.contains("<!-- ordinary -->"))
        #expect(document.text.contains("<!-- gday:t=3:99 -->"))
        #expect(document.citedText.contains("[3:05] # Heading"))
    }
    @Test func typingSplitAndNewLineTimes() {
        var document = NotesDocument("First line <!-- gday:t=1:00 -->")
        document.replace(NSRange(location: 5, length: 0), with: " corrected", clock: 90)
        #expect(document.lines[0].time == 60)
        document.replace(NSRange(location: 5, length: 0), with: "\n", clock: 100)
        #expect(document.lines.map(\.time) == [60, 60])
        document.replace(NSRange(location: document.text.utf16.count, length: 0), with: "\n", clock: 110)
        #expect(document.lines.last?.time == nil)
        document.replace(NSRange(location: document.text.utf16.count, length: 0), with: "New", clock: 120)
        #expect(document.lines.last?.time == 120)
        #expect(document.text == "First\n corrected line\nNew")
    }
    @Test func clockAndLead() {
        #expect(NotesDocument.clock(recording: 10, playback: 20) == 10)
        #expect(NotesDocument.clock(recording: nil, playback: 20) == 20)
        #expect(NotesDocument.clock(recording: nil, playback: nil) == nil)
        #expect(NotesDocument.playbackStart(2) == 0)
        #expect(NotesDocument.playbackStart(12) == 9)
    }
}

@MainActor struct NotesStorageTests {
    @Test func migrateSaveReloadAndStandaloneExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = Meeting(title: "Old", notes: "Original <!-- gday:t=0:12 -->")
        var library = MeetingLibrary(meetings: [meeting])
        library.version = 2
        let original = try JSONEncoder().encode(library)
        try original.write(to: folder.appendingPathComponent("library.json"))
        let store = MeetingStore(dataDirectory: folder)
        #expect(store.errorMessage == nil)
        #expect(store.meetings[0].notes == meeting.notes)
        #expect(try Data(contentsOf: folder.appendingPathComponent("library-v2-backup.json")) == original)
        let object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("library.json")))
            as! [String: Any]
        #expect((object["meetings"] as! [[String: Any]])[0]["notes"] == nil)
        let metadataBefore = try Data(contentsOf: folder.appendingPathComponent("library.json"))
        store.editNotes(id: meeting.id, text: "Edited")
        #expect(try Data(contentsOf: folder.appendingPathComponent("library.json")) == metadataBefore)
        await store.finalizeForQuit()
        let restored = MeetingStore(dataDirectory: folder)
        #expect(restored.meetings[0].notes == "Edited")
        let exported = try JSONEncoder().encode(restored.meetings[0])
        #expect(try JSONDecoder().decode(Meeting.self, from: exported).notes == "Edited")
        #expect(
            try FileManager.default.attributesOfItem(atPath: store.notesStorage.url(meeting.id).path)[.posixPermissions]
                as? Int == 0o600)
    }
    @Test func externalEditsReloadAndConflictsArePreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        let id = store.createMeeting()
        store.editNotes(id: id, text: "Initial")
        #expect(store.flushNotes())
        let file = store.notesStorage.url(id)
        try Data("External".utf8).write(to: file)
        store.openNotes(id: id)
        #expect(store.meetings[0].notes == "External")
        store.editNotes(id: id, text: "App changes")
        try Data("Another external edit".utf8).write(to: file)
        #expect(store.flushNotes())
        #expect(try String(contentsOf: file, encoding: .utf8) == "App changes")
        #expect(
            try String(
                contentsOf: file.deletingLastPathComponent().appendingPathComponent("notes (changed on disk).md"),
                encoding: .utf8) == "Another external edit")
    }
}

extension NotesDocumentTests {
    @Test func malformedHugeTimesAndUnicode() {
        #expect(NotesDocument.seconds("999999999999999999999999:00:00") == nil)
        #expect(NotesDocument.clock(recording: .nan, playback: nil) == nil)
        #expect(NotesDocument.clock(recording: .infinity, playback: nil) == nil)
        #expect(NotesDocument.timestamp(.infinity) == "0:00")
        var document = NotesDocument("🎙️ café <!-- gday:t=0:12 -->\r\nNext <!-- gday:t=0:14 -->")
        let range = (document.text as NSString).range(of: "café")
        document.replace(range, with: "hello", clock: 99)
        #expect(document.markdown == "🎙️ hello <!-- gday:t=0:12 -->\r\nNext <!-- gday:t=0:14 -->")
        let newline = (document.text as NSString).range(of: "\r\n")
        document.replace(newline, with: " ", clock: 100)
        #expect(document.text == "🎙️ hello Next")
        #expect(document.lines[0].time == 12)
    }
}

extension NotesStorageTests {
    @Test func writeFailureKeepsDraftAndPreventsQuit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        let id = store.createMeeting()
        let meetingFolder = store.directory(for: id)
        try FileManager.default.removeItem(at: meetingFolder)
        try Data("Blocks folder creation".utf8).write(to: meetingFolder)
        store.editNotes(id: id, text: "Keep this draft")
        #expect(await store.finalizeForQuit() == false)
        #expect(store.notesStorage.pending[id] == "Keep this draft")
        #expect(store.meetings[0].notes == "Keep this draft")
        store.deleteMeeting(id: id)
        #expect(store.meetings.count == 1)
        #expect(store.notesStorage.pending[id] == "Keep this draft")
        try FileManager.default.removeItem(at: meetingFolder)
        #expect(store.flushNotes())
        #expect(try String(contentsOf: store.notesStorage.url(id), encoding: .utf8) == "Keep this draft")
    }
    @Test func metadataFailureDoesNotRollBackDurableNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        let id = store.createMeeting()
        let index = folder.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        var meeting = store.meetings[0]
        meeting.title = "Can't save title"
        meeting.notes = "Durable notes"
        store.updateMeeting(meeting)
        #expect(store.errorMessage != nil)
        #expect(store.meetings[0].title == "Untitled Meeting")
        #expect(store.meetings[0].notes == "Durable notes")
        #expect(try String(contentsOf: store.notesStorage.url(id), encoding: .utf8) == "Durable notes")
    }
}

@MainActor struct NotesEditorTests {
    @Test func nativeEditingUndoAndPlayback() throws {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.allowsUndo = true
        var saved = ""
        var played: Double?
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { 90 }, canPlay: { true }, play: { played = $0 },
            changed: { saved = $0 }, flush: {})
        text.load("First line <!-- gday:t=0:12 -->")
        text.delegate = text
        text.textStorage?.delegate = text
        text.setSelectedRange(NSRange(location: 5, length: 0))
        text.undoManager?.beginUndoGrouping()
        text.insertText(" new", replacementRange: text.selectedRange())
        text.undoManager?.endUndoGrouping()
        #expect(text.document.text == text.string)
        #expect(saved == "First new line <!-- gday:t=0:12 -->")
        text.undoManager?.undo()
        #expect(text.string == "First line")
        #expect(text.document.markdown == "First line <!-- gday:t=0:12 -->")
        text.undoManager?.redo()
        #expect(text.document.text == text.string)
        #expect(text.document.lines[0].time == 12)
        text.playFromLine(nil)
        #expect(played == 12)
        #expect(text.textLayoutManager != nil)
    }
}

extension NotesDocumentTests {
    @Test func codeAndTableTimesStayOutsideContent() {
        let source = "<!-- gday:t=0:12 -->\n```swift\nlet marker = \"<!-- gday:t=0:14 -->\"\n```\n"
        var document = NotesDocument(source)
        #expect(document.markdown == source)
        #expect(document.text.hasPrefix("```swift"))
        #expect(document.time(atLine: 1) == 12)
        #expect(document.timedLine(for: 1) == 0)
        #expect(document.text.contains("<!-- gday:t=0:14 -->"))
        let index = (document.text as NSString).range(of: "let marker").location
        document.replace(NSRange(location: index, length: 0), with: "// comment\n", clock: 40)
        #expect(!document.markdown.contains("gday:t=0:40"))
        var fresh = NotesDocument("")
        fresh.replace(NSRange(location: 0, length: 0), with: "```\ncode\n```", clock: 20)
        #expect(fresh.markdown == "<!-- gday:t=0:20 -->\n```\ncode\n```")
        var table = NotesDocument("")
        table.replace(
            NSRange(location: 0, length: 0), with: "| Name | Value |\n| --- | --- |\n| One | Two |", clock: 30)
        #expect(table.markdown == "<!-- gday:t=0:30 -->\n| Name | Value |\n| --- | --- |\n| One | Two |")
        #expect(NotesDocument(table.markdown).markdown == table.markdown)
    }
}

extension NotesEditorTests {
    @Test func pasteTimesFollowMeetingAndUndo() {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.allowsUndo = true
        let meetingID = UUID()
        text.editor = MarkdownNotesEditor(
            meetingID: meetingID, markdown: "", editable: true, clock: { 90 }, canPlay: { true }, play: { _ in },
            changed: { _ in }, flush: {})
        text.load("First <!-- gday:t=0:12 -->\n")
        text.delegate = text
        text.textStorage?.delegate = text
        text.notesPasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { text.notesPasteboard.releaseGlobally() }
        text.setSelectedRange(NSRange(location: 0, length: 5))
        text.copy(nil)
        #expect(text.notesPasteboard.string(forType: .string) == "First")
        text.setSelectedRange(NSRange(location: 6, length: 0))
        text.undoManager?.beginUndoGrouping()
        text.paste(nil)
        text.undoManager?.endUndoGrouping()
        #expect(text.document.lines[1].time == 12)
        text.undoManager?.undo()
        #expect(text.document.markdown == "First <!-- gday:t=0:12 -->\n")
        #expect(text.string == text.document.text)
        text.undoManager?.redo()
        #expect(text.document.lines[1].time == 12)
        #expect(text.string == text.document.text)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { 90 }, canPlay: { true }, play: { _ in },
            changed: { _ in }, flush: {})
        text.load("")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.paste(nil)
        #expect(text.document.lines[0].time == 90)
    }
}

extension NotesStorageTests {
    @Test func typingDebouncesOnlyNotesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        let id = store.createMeeting()
        let index = folder.appendingPathComponent("library.json")
        let metadata = try Data(contentsOf: index)
        store.editNotes(id: id, text: "First edit")
        store.editNotes(id: id, text: "Latest edit")
        #expect(try String(contentsOf: store.notesStorage.url(id), encoding: .utf8) == "")
        let deadline = Date().addingTimeInterval(3)
        while !store.notesStorage.pending.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(try String(contentsOf: store.notesStorage.url(id), encoding: .utf8) == "Latest edit")
        #expect(try Data(contentsOf: index) == metadata)
        #expect(store.notesStorage.pending.isEmpty)
    }
}
