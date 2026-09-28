import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct MeetingTitleEditorTests {
    @Test func windowAttachmentFocusesEditorAndSelectsWholeTitle() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = MeetingTitleTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        field.stringValue = "A title with 😀"
        window.contentView?.addSubview(field)
        for _ in 0..<20 {
            if field.currentEditor() != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.firstResponder === field.currentEditor())
        #expect(field.currentEditor() != nil)
        #expect(
            field.currentEditor()?.selectedRange == NSRange(location: 0, length: (field.stringValue as NSString).length)
        )
    }

    @Test func returnCommitsOnceAndEscapeCancelsWithoutBlurCommit() {
        var draft = "Original"
        var completions: [Bool] = []
        let parent = MeetingTitleEditor(
            text: Binding(get: { draft }, set: { draft = $0 }), finish: { completions.append($0) })
        let coordinator = MeetingTitleEditor.Coordinator(parent)
        let editor = NSTextView()
        editor.string = "Changed"
        #expect(
            coordinator.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(draft == "Changed")
        #expect(completions == [false])
        completions = []
        let cancelled = MeetingTitleEditor.Coordinator(parent)
        #expect(
            cancelled.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        cancelled.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(completions == [true])
    }
}
