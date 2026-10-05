import AppKit
import SwiftUI

/// Directory selection is independent of the rotating page window.
struct NativeDirectoryList: NSViewRepresentable {
    let entries: [DirectoryEntry]
    @Binding var selection: Set<UUID>
    var multiple = true
    var label: String
    var reveal: DirectoryReveal? = nil
    var retainedViewport: NativeListViewport? = nil
    var footerText: String? = nil
    var viewport: (UUID, UUID) -> Void
    var delete: (DirectoryEntry) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = DirectoryTable()
        table.style = .inset
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = multiple
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(label)
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.contextMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(row: row) }
        table.remove = { [weak coordinator = context.coordinator] in coordinator?.removeSelection() }
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeDirectoryList
        var rows: [DirectoryEntry] = []
        weak var table: DirectoryTable?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var updating = false
        var revealed: UUID?
        init(_ parent: NativeDirectoryList) {
            self.parent = parent
            revealed = parent.retainedViewport?.revealedID
        }
        func update(_ parent: NativeDirectoryList) {
            guard let table, let scroll else { return }
            let visible = table.rows(in: scroll.contentView.bounds)
            let first = visible.location
            let anchor = rows.indices.contains(first) ? rows[first].id : parent.retainedViewport?.anchor?.id
            let offset =
                rows.indices.contains(first)
                ? scroll.contentView.bounds.minY - table.rect(ofRow: first).minY
                : parent.retainedViewport?.anchor?.offset ?? 0
            updating = true
            let changed = rows != parent.entries || self.parent.footerText != parent.footerText
            self.parent = parent
            if changed {
                rows = parent.entries
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                if let anchor, let position = rows.firstIndex(where: { $0.id == anchor }) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: position).minY + offset))
                }
                else {
                    scroll.contentView.scroll(to: .zero)
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let selected = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if selected != table.selectedRowIndexes { table.selectRowIndexes(selected, byExtendingSelection: false) }
            if let reveal = parent.reveal, revealed != reveal.id,
                let position = rows.firstIndex(where: { $0.id == reveal.targetID })
            {
                table.scrollRowToVisible(position)
                revealed = reveal.id
                parent.retainedViewport?.revealedID = reveal.id
            }
            updating = false
            rememberViewport()
            scrolled()
        }
        func scrolled() {
            if !updating { rememberViewport() }
            guard !updating, let table, let scroll else { return }
            let visible = table.rows(in: scroll.contentView.bounds)
            guard visible.location != NSNotFound, visible.length > 0, rows.indices.contains(visible.location) else {
                return
            }
            let first = rows[visible.location].id
            let last = rows[min(rows.count - 1, NSMaxRange(visible) - 1)].id
            let callback = parent.viewport
            Task { @MainActor in callback(first, last) }
        }
        private func rememberViewport() {
            guard let table, let scroll, let retained = parent.retainedViewport else { return }
            let first = table.rows(in: scroll.contentView.bounds).location
            guard rows.indices.contains(first) else { return }
            retained.anchor = .init(
                id: rows[first].id, offset: scroll.contentView.bounds.minY - table.rect(ofRow: first).minY)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (parent.footerText == nil ? 0 : 1) }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows.indices.contains(row) ? 48 : 40
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let modifiers = NSApplication.shared.currentEvent?.modifierFlags ?? []
            let keepsOffscreen = parent.multiple && (!modifiers.intersection([.command, .shift]).isEmpty)
            let offscreen = keepsOffscreen ? parent.selection.subtracting(rows.map(\.id)) : []
            parent.selection = selected.union(offscreen)
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            rows.indices.contains(row) ? MeetingSelectionRow() : NSTableRowView()
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == rows.count, let text = parent.footerText {
                return NativeListCountCell.make(in: tableView, text: text)
            }
            let id = NSUserInterfaceItemIdentifier("directory-row")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DirectoryCell ?? DirectoryCell()
            cell.identifier = id
            cell.configure(rows[row])
            return cell
        }
        func menu(row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let item = NSMenuItem(
                title: parent.multiple ? "Delete Person…" : "Delete Tag…", action: #selector(removeFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = rows[row].id
            let menu = NSMenu()
            menu.addItem(item)
            return menu
        }
        @objc func removeFromMenu(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID, let row = rows.first(where: { $0.id == id }) {
                parent.delete(row)
            }
        }
        func removeSelection() {
            guard let table, table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else {
                return
            }
            parent.delete(rows[table.selectedRow])
        }
    }
}

final class DirectoryTable: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?
    var remove: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            remove?()
        }
        else {
            super.keyDown(with: event)
        }
    }
}
final class DirectoryCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for field in [name, detail] {
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        textField = name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: DirectoryEntry) {
        name.stringValue = entry.name
        detail.stringValue =
            "\(entry.meetingCount.formatted()) \(entry.meetingCount == 1 ? "meeting" : "meetings")"
            + (entry.isExcluded ? " · Excluded" : "")
        toolTip = entry.name
        needsLayout = true
    }
    override func layout() {
        super.layout()
        name.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20), height: 18)
        detail.frame = NSRect(x: 10, y: 25, width: max(0, bounds.width - 20), height: 15)
    }
}
