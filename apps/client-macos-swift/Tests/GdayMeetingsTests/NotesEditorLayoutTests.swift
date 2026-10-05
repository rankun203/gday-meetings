import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor private struct NotesLayoutHarness: View {
    @ViewState var markdown: String
    let directory: URL
    let meetingID = UUID()

    var body: some View {
        MarkdownNotesEditor(
            meetingID: meetingID, markdown: markdown, editable: true,
            clock: { 25 }, canPlay: { false }, play: { _ in },
            changed: { markdown = $0 }, flush: {}, directory: directory)
    }
}

@MainActor struct NotesEditorLayoutTests {
    @Test(arguments: [false, true])
    func hostedEditorLargePasteFinalImageScrollAndPartialDeletion(fullWorkspace: Bool) async throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = UUID()
        let imageDirectory = store.directory(for: meetingID)
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: imageDirectory)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, alt: "Diagram")
        let small = try NotesImageStore.resized(original, width: 80, directory: imageDirectory)
        let initial = "# Notes\n\n" + original.markdown + "\n\n" + small.markdown + "\nEnd"
        store.meetings = [Meeting(id: meetingID, title: "Layout regression", notes: initial)]
        await store.updateMeeting(store.meetings[0])
        #expect(await store.flushNotes())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root: AnyView =
            fullWorkspace
            ? AnyView(
                MeetingNotesWorkspace(meetingID: meetingID).environmentObject(store).environmentObject(
                    MeetingPlayback()))
            : AnyView(NotesLayoutHarness(markdown: initial, directory: imageDirectory))
        let host = NSHostingView(rootView: root)
        window.contentView = host
        defer { window.close() }
        func drain() async throws {
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(25))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                _ = editor(in: host)?.accessibilityValue()
            }
        }
        func editor(in view: NSView) -> NotesTextView? {
            if let text = view as? NotesTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        try await drain()
        let text = try #require(editor(in: host))
        window.makeFirstResponder(text)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        text.notesPasteboard = pasteboard
        let replacement =
            (1...30).map { "Line \($0): text before the final image." }.joined(separator: "\n")
            + "\n" + small.markdown + "\n"
        pasteboard.setString(replacement, forType: .string)
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        text.paste(nil)
        try await drain()
        if let image = text.images.views.last,
            let manager = text.textLayoutManager, let content = manager.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: image.reference.range.location),
            let fragment = manager.textLayoutFragment(for: location)
        {
            print("Final image frame: \(image.frame); fragment: \(fragment.layoutFragmentFrame)")
            for line in fragment.textLineFragments {
                print("Image line \(line.characterRange): \(line.typographicBounds)")
            }
            let nonemptyBottom =
                fragment.textLineFragments.filter { $0.characterRange.length > 0 }
                .map { $0.typographicBounds.maxY }.max() ?? 0
            let expectedTop = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + nonemptyBottom + 8
            #expect(abs(image.frame.minY - expectedTop) < 1)
        }
        for _ in 0..<4 {
            text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
            try await drain()
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
            try await drain()
        }
        #expect(text.string == replacement)
        let source = text.string as NSString
        let start = source.range(of: "<img").location
        let end = NSMaxRange(source.range(of: "</a>"))
        #expect(start != NSNotFound)
        text.setSelectedRange(NSRange(location: start, length: end - start))
        text.deleteBackward(nil)
        try await drain()
        #expect(!text.string.contains("<img"))
        text.undoManager?.undo()
        try await drain()
        #expect(text.string.contains("<img"))
        // Dismantle while the original files still exist, then let SwiftUI drain
        // its graph teardown before the temporary library is removed.
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        try await drain()
    }
}
