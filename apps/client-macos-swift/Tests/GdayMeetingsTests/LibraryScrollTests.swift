import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct LibraryScrollTests {
    @Test func addingMeetingsPreservesNativeTopSpacing() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        for index in 0..<26 { store.createMeeting(title: "Meeting \(index)") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(
            rootView: LibraryView().environmentObject(store).environmentObject(MeetingPlayback()))
        settle(window)

        // The sidebar fits; the meetings column is the only overflowing scroll view.
        let content = try #require(window.contentView)
        let list = try #require(
            scrollViews(in: content).first {
                ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height
            })
        let initialTop = list.contentView.bounds.minY
        store.createMeeting(title: "Added at the top")
        settle(window)
        #expect(abs(list.contentView.bounds.minY - initialTop) < 0.5)

        let document = try #require(list.documentView)
        document.scroll(NSPoint(x: 0, y: 300))
        settle(window)
        #expect(list.contentView.bounds.minY > initialTop + 100)
        store.createMeeting(title: "Added while browsing older meetings")
        settle(window)
        #expect(abs(list.contentView.bounds.minY - initialTop) < 0.5)

        // Ordinary updates must not force the reader back to the beginning.
        document.scroll(NSPoint(x: 0, y: 300))
        settle(window)
        let browsingTop = list.contentView.bounds.minY
        store.objectWillChange.send()
        settle(window)
        #expect(abs(list.contentView.bounds.minY - browsingTop) < 0.5)
    }

    private func settle(_ window: NSWindow) {
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}
