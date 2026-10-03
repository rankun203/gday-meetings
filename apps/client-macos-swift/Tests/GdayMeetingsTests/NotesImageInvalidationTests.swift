import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesImageInvalidationTests {
    @Test func unchangedLayoutAndAttributesReuseReferencesButCharacterEditsReparse() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: directory)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame.size = NSSize(width: 600, height: 400)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {}, directory: directory)
        var parses = 0
        text.images = NotesImagePresentation(text: text) {
            parses += 1
            return NotesImageReference.parse(in: $0)
        }
        let markup = "![Diagram](\(path))"
        let prefix = "会议 👩🏽‍💻 e\u{301}\n"
        text.load(prefix + markup + "\nText")
        text.images.prepare()
        let image = try #require(text.images.views.first)
        #expect(image.reference.range.location == prefix.utf16.count)
        #expect(parses == 1)
        for _ in 0..<100 {
            text.images.reconcileRanges()
            text.images.prepare()
        }
        #expect(parses == 1)
        text.textStorage?.addAttribute(
            .foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: 1))
        text.images.prepare()
        #expect(parses == 1)
        text.frame.size.width = 300
        text.images.prepare()
        #expect(parses == 1)
        #expect(text.images.views.first === image)

        // Direct storage edits exercise notification invalidation independently of the view delegate.
        text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "新🙂")
        text.images.didChangeText()
        text.images.prepare()
        #expect(parses == 2)
        #expect(image.reference.range.location == prefix.utf16.count + "新🙂".utf16.count)
        text.textStorage?.replaceCharacters(in: image.reference.range, with: "Removed")
        text.images.prepare()
        #expect(parses == 3)
        #expect(text.images.views.isEmpty)
        text.load(markup)
        text.images.prepare()
        #expect(parses == 4)
        #expect(text.images.views.count == 1)

        // Canonically equal Unicode strings can still have different UTF-16 ranges.
        text.load("e\u{301}\n" + markup)
        text.images.prepare()
        #expect(text.images.views.first?.reference.range.location == 3)
        text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
        text.images.prepare()
        #expect(parses == 6)
        #expect(text.images.views.first?.reference.range.location == 2)
    }

    @Test func combinedEditsAndCancelledProposalsKeepUnchangedImages() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: directory)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame.size = NSSize(width: 600, height: 400)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {}, directory: directory)
        text.load("Prefix\n![Diagram](\(path))\nSuffix")
        text.images.prepare()
        let image = try #require(text.images.views.first)
        let storage = try #require(text.textStorage)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "p")
        storage.replaceCharacters(in: NSRange(location: storage.length - 1, length: 1), with: "X")
        storage.endEditing()
        text.images.prepare()
        #expect(text.images.views.first === image)
        storage.beginEditing()
        storage.addAttribute(
            .foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
        storage.replaceCharacters(in: NSRange(location: storage.length - 1, length: 1), with: "x")
        storage.endEditing()
        text.images.prepare()
        #expect(text.images.views.first === image)
        // A rejected proposal must not remove the image on a later unrelated edit.
        text.images.willChange(image.reference.range, replacement: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "P")
        text.images.prepare()
        #expect(text.images.views.first === image)
        let unchanged = storage.string
        text.images.willChange(NSRange(location: 0, length: storage.length), replacement: unchanged)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: unchanged)
        text.images.prepare()
        #expect(text.images.views.first === image)
    }

    @Test func externalAssetReplacementRefreshesWithoutReparsing() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: directory)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame.size = NSSize(width: 600, height: 400)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {}, directory: directory)
        var parses = 0
        text.images = NotesImagePresentation(text: text) {
            parses += 1
            return NotesImageReference.parse(in: $0)
        }
        text.load("![Diagram](\(path))")
        text.images.prepare()
        let original = try #require(text.images.views.first?.image)
        let url = directory.appendingPathComponent(path)
        try fixtures.png(width: 120, height: 160).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        text.images.prepare()
        #expect(parses == 1)
        #expect(text.images.views.first?.image !== original)
        #expect(text.images.views.first?.frame.size == NSSize(width: 60, height: 80))
    }
}
