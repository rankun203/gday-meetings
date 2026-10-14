import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeLibrarySidebarFocusTests {
    @Test func programmaticSelectionDoesNotStealTextFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let field = NSTextField(frame: NSRect(x: 0, y: 260, width: 200, height: 24))
        container.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let responder = window.firstResponder
        var selection: LibraryDestination? = .meetings
        let sidebar = NativeLibrarySidebar(selection: Binding(get: { selection }, set: { selection = $0 }))
        let coordinator = sidebar.makeCoordinator()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 240))
        table.addTableColumn(NSTableColumn(identifier: .init("destination")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        container.addSubview(table)
        table.reloadData()
        for destination in LibraryDestination.allCases {
            selection = destination
            coordinator.update(sidebar)
            #expect(table.selectedRow == destination.rawValue)
            #expect(window.firstResponder === responder)
        }
        selection = nil
        coordinator.update(sidebar)
        #expect(table.selectedRow == -1)
        #expect(window.firstResponder === responder)
    }
}
