import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesImageCursorTests {
    @Test func imageCursorUsesTheSameClampedCornerAsDragging() {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.isEditable = true
        let image = NotesImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        image.text = text
        #expect(image.resizeHandle == NSRect(x: 168, y: 68, width: 32, height: 32))
        #expect(image.cursor(at: NSPoint(x: 170, y: 70)) === NotesImageView.resizeCursor)
        #expect(image.cursor(at: NSPoint(x: 160, y: 70)) === NSCursor.arrow)
        #expect(image.cursor(at: NSPoint(x: 201, y: 101)) == nil)
        text.isEditable = false
        #expect(image.cursor(at: NSPoint(x: 170, y: 70)) === NSCursor.arrow)
        image.frame.size = NSSize(width: 12, height: 8)
        #expect(image.resizeHandle == image.bounds)
        #expect(image.cursor(at: NSPoint(x: -1, y: -1)) == nil)
    }

    @Test func readModeResignsFocusWithoutDiscardingSelectionOrUndo() throws {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = text
        defer { window.contentView = nil }
        var editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "Hello", editable: true,
            clock: { nil }, canPlay: { false }, play: { _ in }, changed: { _ in }, flush: {})
        editor.update(text)
        text.delegate = text
        text.allowsUndo = true
        window.makeFirstResponder(text)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
        undo.endUndoGrouping()
        text.setSelectedRange(NSRange(location: 6, length: 5))
        editor.markdown = text.document.markdown
        editor.editable = false
        editor.update(text)
        #expect(window.firstResponder !== text)
        #expect(text.selectedRange() == NSRange(location: 6, length: 5))
        #expect(undo.canUndo)
        editor.editable = true
        editor.update(text)
        #expect(text.selectedRange() == NSRange(location: 6, length: 5))
        window.makeFirstResponder(text)
        undo.undo()
        #expect(text.string == "Hello")
    }

    @Test func nativeMouseRoutingRetainsImageCursorAfterTextViewHandling() throws {
        _ = NSApplication.shared
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        text.isVerticallyResizable = false
        text.isEditable = true
        let image = NotesImageView(frame: NSRect(x: 20, y: 20, width: 200, height: 100))
        image.text = text
        text.addSubview(image)
        // Both overlapping tracking routes must keep the image cursor, without native text handling.
        let window = NSWindow(contentRect: text.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = text
        defer { window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        text.images.views = [image]
        for (point, expected) in [
            (NSPoint(x: 180, y: 80), NotesImageView.resizeCursor),
            (NSPoint(x: 10, y: 10), NSCursor.arrow),
        ] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: image.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 0, pressure: 0))
            // AppKit's frame-resize cursor resolves to a system cursor when set.
            expected.set()
            let resolvedCursor = NSCursor.current
            NSCursor.iBeam.set()
            text.mouseMoved(with: event)
            #expect(NSCursor.current.isEqual(resolvedCursor))
            text.cursorUpdate(with: event)
            #expect(NSCursor.current.isEqual(resolvedCursor))
            image.mouseMoved(with: event)
            #expect(NSCursor.current.isEqual(resolvedCursor))
            image.cursorUpdate(with: event)
            #expect(NSCursor.current.isEqual(resolvedCursor))
        }
    }
}
