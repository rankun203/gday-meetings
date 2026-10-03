import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesEditorLineIndexTests {
    private func check(_ document: NotesDocument, index: NotesEditorLineIndex) {
        for offset in -1...(document.text.utf16.count + 1) {
            #expect(index.line(at: offset) == document.lineIndex(at: offset))
        }
        for line in document.lines.indices {
            #expect(index.start(of: line) == document.range(of: line).location)
        }
    }

    @Test func indexMatchesDocumentForUnicodeAndLineEndings() {
        for source in [
            "", "\n", "\r\n", "One\n", "文🙂\r\ne\u{301}\n\n👩🏽‍💻",
            "First <!-- gday:t=0:12 -->\r\nSecond\r\n\r\nThird <!-- gday:t=1:03 -->\n",
        ] {
            let document = NotesDocument(source)
            check(document, index: NotesEditorLineIndex(document))
        }
    }

    @Test func documentMutationInvalidatesOffsetsWithoutChangingTimes() {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.load("First <!-- gday:t=0:12 -->\nSecond\nThird <!-- gday:t=1:03 -->")
        check(text.document, index: text.lineLayoutIndex)
        text.document.replace(NSRange(location: 0, length: 0), with: "新🙂\n", clock: nil)
        check(text.document, index: text.lineLayoutIndex)
        let third = text.document.lines.firstIndex { $0.text == "Third" }!
        #expect(text.document.lines[third].time == 63)
        #expect(text.lineLayoutIndex.line(at: text.document.range(of: third).location) == third)
        text.document.setTime(75, line: third)
        check(text.document, index: text.lineLayoutIndex)
        #expect(text.document.lines[third].time == 75)
        text.load("")
        check(text.document, index: text.lineLayoutIndex)
    }

    @Test func nativeUndoRedoInvalidatesCachedOffsets() throws {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.delegate = text
        text.allowsUndo = true
        text.load("First <!-- gday:t=0:12 -->\nSecond\n")
        let original = text.document
        check(text.document, index: text.lineLayoutIndex)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText("新🙂\n", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        let changed = text.document
        check(text.document, index: text.lineLayoutIndex)
        undo.undo()
        #expect(text.document == original)
        check(text.document, index: text.lineLayoutIndex)
        undo.redo()
        #expect(text.document == changed)
        check(text.document, index: text.lineLayoutIndex)
    }
}
