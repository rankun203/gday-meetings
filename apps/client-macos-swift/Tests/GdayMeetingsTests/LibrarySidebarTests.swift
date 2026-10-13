import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct LibrarySidebarTests {
    @Test func sidebarTransitionKeepsWorkspaceInsideWindow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-sidebar-bounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = LibrarySidebarControl()
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = await store.createMeeting(title: "Synthetic meeting")
        store.managedTasks = [
            ManagedTaskRecord(
                kind: .summary, meetingID: meetingID, meetingTitle: "Synthetic meeting",
                providerName: "Synthetic provider", state: .failed,
                errorMessage: "The summary could not be created.", isPreview: true)
        ]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: LibraryView(sidebar: control)
                .environmentObject(store).environmentObject(MeetingPlayback()))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.close()
            control.disconnect()
        }
        func splits(in view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap { splits(in: $0) }
        }
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(in: $0) }
        }
        let connected = try await waitForMainActorTestCondition {
            host.layoutSubtreeIfNeeded()
            return control.isConnected && !splits(in: host).isEmpty
        }
        #expect(connected)
        for width in [1200.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 800))
            _ = await SidebarPerformanceTests.run(seconds: 0.5, rate: 0, window: window) { _ in }
            for _ in 0..<2 {
                let split = try #require(splits(in: host).first)
                let controller = try #require(split.delegate as? NSSplitViewController)
                controller.toggleSidebar(nil)
                var overflow: CGFloat = 0
                var samples = 0
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while ContinuousClock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    for split in splits(in: host) {
                        let bounds = split.convert(split.bounds, to: host)
                        overflow = max(overflow, max(-bounds.minX, bounds.maxX - host.bounds.width))
                        for column in split.arrangedSubviews where !column.isHidden {
                            let columnBounds = column.convert(column.bounds, to: host)
                            overflow = max(overflow, columnBounds.maxX - host.bounds.width)
                        }
                        if let detail = split.arrangedSubviews.last {
                            for view in descendants(in: detail) where !view.isHiddenOrHasHiddenAncestor {
                                let rect = view.convert(view.bounds, to: host)
                                overflow = max(overflow, rect.maxX - host.bounds.width)
                                if let layer = view.layer?.presentation(), let root = host.layer?.presentation() {
                                    let displayed = layer.convert(layer.bounds, to: root)
                                    overflow = max(overflow, displayed.maxX - host.bounds.width)
                                }
                            }
                        }
                        samples += 1
                    }
                    try await Task.sleep(for: .milliseconds(4))
                }
                #expect(samples > 1)
                #expect(overflow <= 1, "Workspace overflow at width \(width): \(overflow) points")
            }
        }
    }

    @Test func selectingAcrossSplitShapesKeepsSidebarKeyboardFocus() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-sidebar-focus-\(UUID())")
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
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        func sidebar() -> NSTableView? {
            guard let content = window.contentView else { return nil }
            // This empty fixture has only the five destination rows; no meeting
            // or task table can be mistaken for the native sidebar.
            return tables(in: content).first { $0.numberOfRows == 5 }
        }
        let connected = try await waitForMainActorTestCondition {
            window.contentView?.layoutSubtreeIfNeeded()
            return control.isConnected
        }
        #expect(connected)
        control.toggle(reduceMotion: true)
        let appeared = try await waitForMainActorTestCondition {
            window.contentView?.layoutSubtreeIfNeeded()
            return sidebar() != nil
        }
        #expect(appeared)
        for target in [3, 0] {  // Meetings → Tasks → Meetings replaces the split shape twice.
            let original = try #require(sidebar())
            #expect(window.makeFirstResponder(original))
            if target == LibraryDestination.tasks.rawValue {
                control.toggle(reduceMotion: true)
                let collapsed = try await waitForMainActorTestCondition { !control.expanded }
                #expect(collapsed)
            }
            original.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            let retained = try await waitForMainActorTestCondition {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let replacement = sidebar(), replacement !== original, replacement.selectedRow == target,
                    let responder = window.firstResponder as? NSView
                else { return false }
                return responder === replacement || responder.isDescendant(of: replacement)
            }
            #expect(
                retained,
                "Target \(target), selected \(sidebar()?.selectedRow ?? -1), replaced \(sidebar() !== original), responder \(String(describing: window.firstResponder))"
            )
            #expect(control.expanded, "Leaving Meetings reveals the sidebar; returning keeps it open")
        }
    }

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
        #expect(!control.expanded && !control.rowsVisible)
        control.toggle(reduceMotion: true)
        let initiallyExpanded = await settledSidebar(expanded: true)
        #expect(initiallyExpanded)
        control.toggle(reduceMotion: false)
        await settle(0.1)
        control.toggle(reduceMotion: false)
        // Native split navigation owns the transition; expanding it must not
        // temporarily hide destination rows.
        #expect(control.expanded && control.rowsVisible)
        // Native split navigation does not promise a SwiftUI animation completion
        // callback. Validate stable column feedback before another scenario.
        let expandedAfterReversal = await settledSidebar(expanded: true)
        #expect(expandedAfterReversal)
        control.toggle(reduceMotion: true)
        let collapsedWithoutMotion = await settledSidebar(expanded: false)
        #expect(collapsedWithoutMotion)
        control.toggle(reduceMotion: true)
        let expandedWithoutMotion = await settledSidebar(expanded: true)
        #expect(expandedWithoutMotion)
    }
}
