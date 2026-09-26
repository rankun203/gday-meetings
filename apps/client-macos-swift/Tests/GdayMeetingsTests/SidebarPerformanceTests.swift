import AppKit
import Foundation
import SwiftUI
import Testing

@testable import GdayMeetings

/// An opt-in repeatable workload, not a machine-dependent CI threshold.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
struct SidebarPerformanceTests {
    static func run(seconds: Double, rate: Double, window: NSWindow, tick: (Int) -> Void) async
        -> RecordingPerformanceTests.Usage
    {
        let wall = ProcessInfo.processInfo.systemUptime
        let thread = RecordingPerformanceTests.threadCPU()
        let process = RecordingPerformanceTests.processCPU()
        var next = wall
        var count = 0
        while ProcessInfo.processInfo.systemUptime - wall < seconds {
            if rate > 0, ProcessInfo.processInfo.systemUptime >= next {
                tick(count)
                count += 1
                next += 1 / rate
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(4))
        }
        return RecordingPerformanceTests.Usage(
            mainThreadSeconds: RecordingPerformanceTests.threadCPU() - thread,
            processSeconds: RecordingPerformanceTests.processCPU() - process,
            wallSeconds: ProcessInfo.processInfo.systemUptime - wall)
    }

    @Test func repeatedSidebarTransitions() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-sidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        var fixtureID: UUID?
        if let path = ProcessInfo.processInfo.environment["GDAY_SIDEBAR_FIXTURE"] {
            try store.importLegacyLibrary(url: URL(fileURLWithPath: path))
            fixtureID = try #require(store.meetings.first?.id)
            print("PERF sidebar fixture: \(store.meetings.first?.transcript.count ?? 0) segments")
        }
        for index in 0..<40 {
            let id = store.createMeeting(title: "Meeting \(index)")
            if var meeting = store.meetings.first(where: { $0.id == id }) {
                meeting.notes = String(repeating: "Discuss delivery dates and project owners.\n", count: 50)
                store.updateMeeting(meeting)
            }
        }
        let sidebar = LibrarySidebarControl()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            sidebar.disconnect()
        }
        window.contentView = NSHostingView(
            rootView: LibraryView(sidebar: sidebar, selectedMeetingID: fixtureID).environmentObject(store)
                .environmentObject(MeetingPlayback()))
        _ = await Self.run(seconds: 1, rate: 0, window: window) { _ in }
        // The synthetic workload selects Notes through the recording-ID change handler.
        // An imported fixture starts on Transcript. No capture or service request starts.
        if fixtureID == nil { store.recordingID = store.meetings.first?.id }
        _ = await Self.run(seconds: 0.5, rate: 0, window: window) { _ in }
        store.recordingID = nil
        _ = await Self.run(seconds: 0.5, rate: 0, window: window) { _ in }
        #expect(sidebar.isConnected)
        let idle = await Self.run(seconds: 2, rate: 0, window: window) { _ in }
        RecordingPerformanceTests.report("sidebar idle", idle)
        var expansionStarted: TimeInterval?
        var expansionDurations: [TimeInterval] = []
        sidebar.completed = { expanded in
            if expanded, let expansionStarted {
                expansionDurations.append(ProcessInfo.processInfo.systemUptime - expansionStarted)
            }
        }
        let animated = await Self.run(seconds: 6, rate: 2, window: window) { _ in
            expansionStarted = sidebar.expanded ? nil : ProcessInfo.processInfo.systemUptime
            sidebar.toggle(reduceMotion: false)
        }
        RecordingPerformanceTests.report("sidebar 12 animated toggles", animated)
        print("PERF sidebar expansion completion seconds: \(expansionDurations)")
        #expect(expansionDurations.count == 6)
        #expect(expansionDurations.allSatisfy { $0 >= 0.20 })
        expansionStarted = nil
        _ = await Self.run(seconds: 0.5, rate: 0, window: window) { _ in }
        #expect(sidebar.expanded && sidebar.rowsVisible)
        let immediate = await Self.run(seconds: 6, rate: 2, window: window) { _ in
            sidebar.toggle(reduceMotion: true)
        }
        RecordingPerformanceTests.report("sidebar 12 reduced-motion toggles", immediate)
        #expect(sidebar.expanded && sidebar.rowsVisible)
    }
}
