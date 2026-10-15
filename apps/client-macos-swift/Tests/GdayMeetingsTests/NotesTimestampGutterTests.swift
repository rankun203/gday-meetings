import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesTimestampGutterTests {
    @Test(arguments: [65.0, 3599.9, 3600.0, 45296.7, 359999.96, 360000.1])
    func completeTimestampFitsNativeButton(time: TimeInterval) throws {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let marker = NotesDocument.timestamp(time)
        let storedTime = try #require(NotesDocument.seconds(marker))
        text.load("Example <!-- gday:t=\(marker) -->")
        text.layoutSubtreeIfNeeded()
        let button = try #require(text.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        // The stored marker rounds to tenths before the UI omits fractional seconds.
        // In particular, 359999.96 is stored as 100:00:00.
        #expect(button.title == NotesDocument.displayTimestamp(storedTime))
        #expect(button.frame.width >= (button.cell?.cellSize.width ?? .infinity))
        #expect(button.frame.maxX < text.textContainerOrigin.x)
        #expect(text.document.markdown == "Example <!-- gday:t=\(NotesDocument.timestamp(time)) -->")
    }

    @Test func hourBoundaryDoesNotMoveNotes() {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        text.load("Example <!-- gday:t=59:59.9 -->")
        text.layoutSubtreeIfNeeded()
        let before = text.textContainerOrigin.x
        text.document.setTime(3600, line: 0)
        text.needsLayout = true
        text.layoutSubtreeIfNeeded()
        #expect(text.textContainerOrigin.x == before)
        #expect(text.lineLayoutIndex.latestTimestamp == 3600)
    }

    @Test func playbackAvailabilityUpdatesWithoutRelayout() throws {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        var available = false
        let editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "Example <!-- gday:t=1:02:03 -->", editable: true,
            clock: { nil }, canPlay: { available }, play: { _ in }, changed: { _ in }, flush: {})
        text.editor = editor
        text.isEditable = true
        text.load(editor.markdown)
        text.layoutSubtreeIfNeeded()
        let button = try #require(text.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        #expect(!button.isEnabled)
        text.needsLayout = false
        available = true
        editor.update(text)
        #expect(button.isEnabled)
        #expect(!text.needsLayout)
        available = false
        editor.update(text)
        #expect(!button.isEnabled)
    }
}
