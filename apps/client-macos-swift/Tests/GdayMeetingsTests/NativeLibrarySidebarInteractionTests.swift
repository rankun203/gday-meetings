import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeLibrarySidebarInteractionTests {
    @Test func mouseSelectionCommitsAfterTrackingAndTransfersFocusOnce() {
        var selection: LibraryDestination? = .meetings
        var writes = 0
        let request = LibrarySidebarFocusRequest()
        let sidebar = NativeLibrarySidebar(
            selection: Binding(
                get: { selection },
                set: {
                    selection = $0
                    writes += 1
                }),
            twoColumn: false, focusRequest: request)
        let coordinator = sidebar.makeCoordinator()
        let table = LibrarySidebarTable()
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
        #expect(!request.matches(.tasks, instance: UUID()))
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(selection == .tasks)
        #expect(writes == 1)
        #expect(request.consume(for: .tasks, instance: UUID()))
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(writes == 1)
        #expect(!request.matches(.tasks, instance: UUID()))

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
