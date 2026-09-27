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
        #expect(control.expanded && !control.rowsVisible)
        let expansionStarted = ContinuousClock.now
        await settle(0.18)
        // Other main-actor suites can resume this task after the animation has
        // completed. Assert the intermediate state only while it is observable.
        let observedBeforeCompletion = expansionStarted.duration(to: .now) < .milliseconds(250)
        if ProcessInfo.processInfo.environment["GDAY_SIDEBAR_STRICT_TIMING"] == "1" {
            #expect(observedBeforeCompletion, "Run this timing check without parallel main-actor suites.")
        }
        if observedBeforeCompletion {
            #expect(control.expanded && !control.rowsVisible)
        }
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
