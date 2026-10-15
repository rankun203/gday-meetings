import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeLibrarySidebarInteractionTests {
    @Test func contentRefreshPreservesPendingPointerSelection() {
        var selection: LibraryDestination? = .meetings
        var writes = 0
        let sidebar = NativeLibrarySidebar(
            selection: Binding(
                get: { selection },
                set: {
                    selection = $0
                    writes += 1
                }))
        let coordinator = sidebar.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("destination")))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        coordinator.update(sidebar)

        // AppKit changes its selected row before completing pointer tracking.
        // Playback or a focus change can refresh SwiftUI in that interval.
        table.selectRowIndexes(IndexSet(integer: LibraryDestination.tasks.rawValue), byExtendingSelection: false)
        for _ in 0..<3 { coordinator.update(sidebar) }
        #expect(table.selectedRow == LibraryDestination.tasks.rawValue)
        #expect(selection == .meetings)
        #expect(writes == 0)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(selection == .tasks)
        #expect(writes == 1)

        // A programmatic return to the previous destination must still apply,
        // even before SwiftUI refreshes after the pointer selection.
        selection = .meetings
        coordinator.update(sidebar)
        #expect(table.selectedRow == LibraryDestination.meetings.rawValue)
        selection = .agents
        coordinator.update(sidebar)
        #expect(table.selectedRow == LibraryDestination.agents.rawValue)
        selection = nil
        coordinator.update(sidebar)
        #expect(table.selectedRow == -1)
        #expect(writes == 1)
    }

    @Test func selectionPublishesOnceAfterTracking() {
        var selection: LibraryDestination? = .meetings
        var writes = 0
        let sidebar = NativeLibrarySidebar(
            selection: Binding(
                get: { selection },
                set: {
                    selection = $0
                    writes += 1
                }))
        let coordinator = sidebar.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("destination")))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        // Model the native selection already present during mouse tracking,
        // before AppKit delivers its final selection notification.
        table.selectRowIndexes(IndexSet(integer: LibraryDestination.tasks.rawValue), byExtendingSelection: false)
        let delegate: any NSTableViewDelegate = coordinator
        delegate.tableViewSelectionIsChanging?(
            Notification(name: NSTableView.selectionIsChangingNotification, object: table))
        #expect(selection == .meetings)
        #expect(writes == 0)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(selection == .tasks)
        #expect(writes == 1)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(writes == 1)

        // Keyboard changes still reach navigation through the final notification.
        table.selectRowIndexes(IndexSet(integer: LibraryDestination.people.rawValue), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(selection == .people)
        #expect(writes == 2)
    }

    @Test func hoverDoesNotChangeSelectionOrLayoutAndClearsOnExit() {
        let row = LibrarySidebarRow(frame: NSRect(x: 0, y: 0, width: 240, height: 31))
        let frame = row.frame
        row.updateTrackingAreas()
        row.updateTrackingAreas()
        #expect(row.trackingAreas.count == 1)
        #expect(row.trackingAreas[0].options.contains(.inVisibleRect))
        #expect(row.trackingAreas[0].options.contains(.activeInKeyWindow))
        row.mouseEntered(with: NSEvent())
        #expect(row.isHovered)
        #expect(!row.isSelected)
        #expect(row.frame == frame)
        row.mouseExited(with: NSEvent())
        #expect(!row.isHovered)
        row.isSelected = true
        row.mouseEntered(with: NSEvent())
        #expect(row.isSelected)
        row.viewDidMoveToWindow()
        #expect(!row.isHovered)
    }
}
