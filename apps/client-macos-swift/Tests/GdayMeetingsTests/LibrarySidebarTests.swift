import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct LibrarySidebarTests {
    @Test func reversalIgnoresStaleCompletionAndReduceMotionRestoresRows() async {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-sidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = LibrarySidebarControl()
        let store = MeetingStore(dataDirectory: directory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LibraryView(sidebar: control)
                .environmentObject(store).environmentObject(MeetingPlayback()))
        defer {
            window.close()
            control.disconnect()
        }
        func settle(_ seconds: Double) async {
            _ = await SidebarPerformanceTests.run(seconds: seconds, rate: 0, window: window) { _ in }
        }
        await settle(0.1)
        #expect(control.isConnected)
        control.toggle(reduceMotion: false)
        await settle(0.1)
        control.toggle(reduceMotion: false)
        await settle(0.18)
        #expect(control.expanded && !control.rowsVisible)
        await settle(0.4)
        #expect(control.rowsVisible)
        control.toggle(reduceMotion: true)
        await settle(0.02)
        #expect(!control.expanded && !control.rowsVisible)
        control.toggle(reduceMotion: true)
        await settle(0.02)
        #expect(control.expanded && control.rowsVisible)
    }
}
