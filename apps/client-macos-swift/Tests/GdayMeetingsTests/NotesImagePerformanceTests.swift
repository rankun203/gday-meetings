import AppKit
import Testing

@testable import GdayMeetings

@Suite @MainActor struct NotesImagePerformanceTests {
    @Test func repeatedEditsAndDecorationReconciliation() throws {
        guard ProcessInfo.processInfo.environment["GDAY_NOTES_IMAGE_BENCHMARK"] == "1" else { return }
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
        let paragraph = "会议记录 👩🏽‍💻 e\u{301} Review the proposed change and follow-up.\n"
        text.load(String(repeating: paragraph, count: 300) + String(repeating: "![Diagram](\(path))\n", count: 4))
        text.images.prepare()
        let started = ContinuousClock.now
        for _ in 0..<100 {
            text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "文🙂")
            text.images.didChangeText()
            for _ in 0..<20 { text.images.reconcileRanges() }
            text.images.prepare()
        }
        print("Notes image benchmark: 100 edits, 2,000 unchanged reconciliations, \(started.duration(to: .now))")
        #expect(text.images.views.count == 4)
        #expect(text.images.views.first?.reference.range.location == paragraph.utf16.count * 300 + 300)
    }
}
