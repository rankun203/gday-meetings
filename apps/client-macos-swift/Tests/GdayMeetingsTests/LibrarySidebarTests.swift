import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct LibrarySidebarTests {
    @Test func rapidReversalKeepsNativeColumnContentAvailable() async {
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
        func settledSidebar(expanded: Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var stableSince: ContinuousClock.Instant?
            while ContinuousClock.now < deadline {
                await settle(0.02)
                if control.expanded == expanded && control.rowsVisible == expanded {
                    if let stableSince, stableSince.duration(to: .now) >= .milliseconds(350) { return true }
                    if stableSince == nil { stableSince = .now }
                }
                else {
                    stableSince = nil
                }
            }
            return false
        }
        await settle(0.1)
        #expect(control.isConnected)
        control.toggle(reduceMotion: false)
        await settle(0.1)
        var completedExpansion = false
        control.completed = { expanded in completedExpansion = expanded }
        control.toggle(reduceMotion: false)
        // Native split navigation owns the transition; expanding it must not
        // temporarily hide the search field and destination rows.
        #expect(control.expanded && control.rowsVisible)
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !completedExpansion && ContinuousClock.now < completionDeadline {
            await settle(0.02)
        }
        #expect(completedExpansion)
        // SwiftUI animation completion does not complete the native split-view
        // transition. Require stable feedback before starting another scenario.
        let expandedAfterReversal = await settledSidebar(expanded: true)
        #expect(expandedAfterReversal)
        control.completed = nil
        control.toggle(reduceMotion: true)
        let collapsedWithoutMotion = await settledSidebar(expanded: false)
        #expect(collapsedWithoutMotion)
        control.toggle(reduceMotion: true)
        let expandedWithoutMotion = await settledSidebar(expanded: true)
        #expect(expandedWithoutMotion)
    }
}
