import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesStyleInvalidationTests {
    private func editor(_ source: String) -> NotesTextView {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.load(source)
        text.prepareImageLayout()
        return text
    }

    private func expectSameStyleAsFullPass(_ text: NotesTextView) throws {
        text.prepareImageLayout()
        let fresh = editor(text.string)
        let actual = try #require(text.textStorage)
        let expected = try #require(fresh.textStorage)
        for offset in 0..<actual.length {
            #expect(
                actual.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
                    == expected.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            #expect(
                actual.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
                    == expected.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
        }
    }

    @Test func unchangedPreparationAndOtherParagraphsKeepAttributes() throws {
        let text = editor("First paragraph\n**Second paragraph**")
        let storage = try #require(text.textStorage)
        storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: NSRange(location: 0, length: 5))
        for _ in 0..<30 { text.prepareImageLayout() }
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemPink)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "文")
        text.prepareImageLayout()
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemPink)
    }

    @Test func unicodeAndGroupedChangesMatchFullStyling() throws {
        let text = editor("# e\u{301} 👩🏽‍💻\nPlain paragraph\n**Bold 文**\n> Quote")
        let storage = try #require(text.textStorage)
        // Multiple pending revisions shift the earlier dirty paragraph in UTF-16.
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: " added")
        storage.replaceCharacters(in: NSRange(location: 2, length: 2), with: "é")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "🙂\n")
        try expectSameStyleAsFullPass(text)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "# Title")
        storage.addAttribute(
            .foregroundColor, value: NSColor.systemPink, range: NSRange(location: 0, length: storage.length))
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n`Code`")
        storage.endEditing()
        try expectSameStyleAsFullPass(text)
        let newline = (storage.string as NSString).range(of: "\n")
        storage.replaceCharacters(in: newline, with: " ")
        try expectSameStyleAsFullPass(text)
    }

    @Test func deletingAllTextThenTypingRestylesNewContent() throws {
        let text = editor("# Heading\n**Bold 文**")
        let storage = try #require(text.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        text.prepareImageLayout()
        #expect(storage.length == 0)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "> 新🙂\n`Code`")
        try expectSameStyleAsFullPass(text)
    }

    @Test func nativeUndoRedoRestylesChangedParagraph() throws {
        let text = editor("Plain 文\nOther paragraph")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.delegate = text
        text.allowsUndo = true
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        try expectSameStyleAsFullPass(text)
        undo.undo()
        #expect(text.string == "Plain 文\nOther paragraph")
        try expectSameStyleAsFullPass(text)
        undo.redo()
        #expect(text.string.hasPrefix("# "))
        try expectSameStyleAsFullPass(text)
    }
}
