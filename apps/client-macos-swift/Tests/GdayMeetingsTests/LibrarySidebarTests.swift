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
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits(in: $0) }
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
            for programmatic in [true, true, false, false] {
                let split = try #require(splits(in: host).first)
                let controller = try #require(split.delegate as? NSSplitViewController)
                let originalWindowWidth = window.frame.width
                if programmatic {
                    control.toggle(reduceMotion: true)
                }
                else {
                    controller.toggleSidebar(nil)
                }
                var windowWidthChange: CGFloat = 0
                var overflow: CGFloat = 0
                var samples = 0
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while ContinuousClock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    windowWidthChange = max(windowWidthChange, abs(window.frame.width - originalWindowWidth))
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
                #expect(
                    windowWidthChange <= 1,
                    "Window width changed by \(windowWidthChange) points at width \(width), programmatic \(programmatic)"
                )
                #expect(samples > 1)
                #expect(overflow <= 1, "Workspace overflow at width \(width): \(overflow) points")
                let workspaceSplit = try #require(splits(in: host).first { $0 !== split })
                let directoryPane = try #require(workspaceSplit.arrangedSubviews.first)
                let detailPane = try #require(workspaceSplit.arrangedSubviews.last)
                // The native host extends beneath the floating sidebar. Measure
                // visible content, while the divider uses the full host width.
                func contentWidth(_ view: NSView) -> CGFloat {
                    view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
                }
                let originalHostWidth = directoryPane.frame.width
                let originalDirectoryWidth = contentWidth(directoryPane)
                let targetWidth: CGFloat = originalDirectoryWidth > 270 ? 250 : 300
                let horizontalInset = directoryPane.safeAreaInsets.left + directoryPane.safeAreaInsets.right
                workspaceSplit.setPosition(targetWidth + horizontalInset, ofDividerAt: 0)
                _ = await SidebarPerformanceTests.run(seconds: 0.2, rate: 0, window: window) { _ in }
                if width == 1200 {
                    #expect(abs(contentWidth(directoryPane) - originalDirectoryWidth) > 1)
                }
                #expect(contentWidth(directoryPane) >= 249 && contentWidth(directoryPane) <= 361)
                #expect(contentWidth(detailPane) >= AppTheme.minimumDetailWidth - 1)
                #expect(abs(window.frame.width - originalWindowWidth) <= 1)
                let workspaceBounds = workspaceSplit.convert(workspaceSplit.bounds, to: host)
                #expect(workspaceBounds.minX >= -1 && workspaceBounds.maxX <= host.bounds.width + 1)
                workspaceSplit.setPosition(originalHostWidth, ofDividerAt: 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func selectingDestinationsRetainsSidebarIdentityAndFocus(startCollapsed: Bool) async throws {
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
        _ = await SidebarPerformanceTests.run(seconds: 0.5, rate: 0, window: window) { _ in }
        func outerController() -> NSSplitViewController? {
            func find(in view: NSView) -> NSSplitViewController? {
                if let split = view as? NSSplitView,
                    let controller = split.delegate as? NSSplitViewController,
                    controller.splitViewItems.contains(where: { $0.behavior == .sidebar })
                {
                    return controller
                }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return window.contentView.flatMap { find(in: $0) }
        }
        let persistentSidebar = try #require(sidebar())
        let persistentController = try #require(outerController())
        for target in [3, 4, 1, 2, 0, 3, 0] {
            let original = try #require(sidebar())
            #expect(window.makeFirstResponder(original))
            let revealsSidebar = startCollapsed && target == LibraryDestination.tasks.rawValue
            if revealsSidebar {
                control.toggle(reduceMotion: true)
                let collapsed = try await waitForMainActorTestCondition { !control.expanded }
                #expect(collapsed)
            }
            let originalWindowWidth = window.frame.width
            original.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            // Drain the SwiftUI navigation transaction before checking identity;
            // native selection changes synchronously, before workspace updates.
            _ = await SidebarPerformanceTests.run(seconds: 0.2, rate: 0, window: window) { _ in }
            let retained = try await waitForMainActorTestCondition {
                window.contentView?.layoutSubtreeIfNeeded()
                guard control.expanded, let replacement = sidebar(), replacement === persistentSidebar,
                    replacement.selectedRow == target
                else { return false }
                // A hidden sidebar cannot originate a keyboard selection. This
                // case models programmatic navigation and must not steal focus.
                if revealsSidebar { return true }
                guard let responder = window.firstResponder as? NSView else { return false }
                return responder === replacement || responder.isDescendant(of: replacement)
            }
            #expect(
                retained,
                "Target \(target), selected \(sidebar()?.selectedRow ?? -1), retained \(sidebar() === persistentSidebar), responder \(String(describing: window.firstResponder))"
            )
            #expect(outerController() === persistentController)
            #expect(control.expanded, "Leaving Meetings reveals the sidebar; returning keeps it open")
            #expect(abs(window.frame.width - originalWindowWidth) <= 1)
        }
    }

    @Test func personSelectionPreservesNativeWorkspaceDivider() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-person-divider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = LibrarySidebarControl()
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        _ = await store.addPerson(name: "Alex Example")
        _ = await store.addPerson(name: "Sam Example")
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
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
        }
        func settle() async {
            _ = await SidebarPerformanceTests.run(seconds: 0.3, rate: 0, window: window) { _ in }
        }
        #expect(try await waitForMainActorTestCondition { control.isConnected })
        control.toggle(reduceMotion: true)
        await settle()
        let sidebar = try #require(descendants(NSTableView.self, in: host).first { $0.numberOfRows == 5 })
        sidebar.selectRowIndexes(IndexSet(integer: LibraryDestination.people.rawValue), byExtendingSelection: false)
        #expect(
            try await waitForMainActorTestCondition {
                host.layoutSubtreeIfNeeded()
                return descendants(DirectoryTable.self, in: host).contains { $0.numberOfRows >= 2 }
            })
        await settle()
        let people = try #require(descendants(DirectoryTable.self, in: host).first)
        let split = try #require(descendants(NSSplitView.self, in: host).last)
        let pane = try #require(split.arrangedSubviews.first)
        let detail = try #require(split.arrangedSubviews.last)
        let target: CGFloat = 275 + pane.safeAreaInsets.left + pane.safeAreaInsets.right
        split.setPosition(target, ofDividerAt: 0)
        await settle()
        let initialWidth = pane.frame.width
        for row in [0, 1, 0, 1] {
            people.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await settle()
            let current = try #require(descendants(NSSplitView.self, in: host).last)
            #expect(current === split)
            #expect(current.arrangedSubviews.first === pane)
            #expect(current.arrangedSubviews.last === detail)
            #expect(
                abs(pane.frame.width - initialWidth) <= 1,
                "Person selection changed directory width from \(initialWidth) to \(pane.frame.width)")
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
