import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptKeyboardSelectionTests {
    @Test func arrowNavigationSelectsVisibleKeyboardTargetAndFocusExitClearsEmphasis() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = TranscriptNativeTable(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let rows = KeyboardTranscriptRows()
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = rows
        table.delegate = rows
        table.headerView = nil
        table.selectionHighlightStyle = .none
        window.contentView = table
        table.reloadData()
        #expect(window.makeFirstResponder(table))
        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false,
                keyCode: 125))
        table.keyDown(with: down)
        #expect(table.selectedRow == 0)
        #expect(table.keyboardSelection)
        table.keyDown(with: down)
        #expect(table.selectedRow == 1)
        var editedRow = -1
        table.editSelected = { editedRow = table.selectedRow }
        let enter = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: enter)
        #expect(editedRow == 1)
        #expect(window.makeFirstResponder(nil))
        #expect(!table.keyboardSelection)
        #expect(table.selectedRow == 1)
    }
}

@MainActor private final class KeyboardTranscriptRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TranscriptNativeRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "Synthetic passage \(row + 1)")
    }
}
