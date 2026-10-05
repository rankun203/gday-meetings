import AppKit
import SwiftUI

struct NativeTaskList: NSViewRepresentable {
    let rows: [TaskHistoryRow]
    @Binding var selection: UUID?
    var revealID: UUID?
    var viewport: (UUID, UUID, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Tasks")
        let column = NSTableColumn(identifier: .init("task"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
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
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeTaskList
        var rows: [TaskHistoryRow] = []
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var updating = false
        var offset: CGFloat = 0
        var revealed: UUID?
        init(_ parent: NativeTaskList) { self.parent = parent }
        func update(_ value: NativeTaskList) {
            guard let table, let scroll else { return }
            let first = table.rows(in: scroll.contentView.bounds).location
            let anchor = rows.indices.contains(first) ? rows[first].id : nil
            let delta = anchor == nil ? 0 : scroll.contentView.bounds.minY - table.rect(ofRow: first).minY
            updating = true
            let changed = rows != value.rows
            parent = value
            if changed {
                rows = value.rows
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                if let anchor, let position = rows.firstIndex(where: { $0.id == anchor }) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: position).minY + delta))
                }
                else {
                    scroll.contentView.scroll(to: .zero)
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if let id = value.selection, let position = rows.firstIndex(where: { $0.id == id }) {
                if table.selectedRow != position {
                    table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
                }
            }
            else {
                table.deselectAll(nil)
            }
            if let id = value.revealID, revealed != id, let position = rows.firstIndex(where: { $0.id == id }) {
                table.scrollRowToVisible(position)
                revealed = id
            }
            offset = scroll.contentView.bounds.minY
            updating = false
            if rows.count <= 50 { report(newer: false) }
        }
        func scrolled() {
            guard !updating, let scroll else { return }
            let position = scroll.contentView.bounds.minY
            guard abs(position - offset) > 0.5 else { return }
            let newer = position < offset
            offset = position
            report(newer: newer)
        }
        func report(newer: Bool) {
            guard let table, let scroll else { return }
            let visible = table.rows(in: scroll.contentView.bounds)
            guard visible.location != NSNotFound, visible.length > 0, rows.indices.contains(visible.location) else {
                return
            }
            let first = rows[visible.location].id
            let last = rows[min(rows.count - 1, NSMaxRange(visible) - 1)].id
            let callback = parent.viewport
            Task { @MainActor in callback(first, last, newer) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            MeetingSelectionRow()
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow) else { return }
            parent.selection = rows[table.selectedRow].id
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("task-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TaskCell ?? TaskCell()
            cell.identifier = identifier
            cell.configure(rows[row])
            return cell
        }
    }
}

private final class TaskCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: TaskHistoryRow) {
        switch row {
        case .managed(let task):
            title.stringValue = task.meetingTitle
            let kind = task.kind == .diarization ? "Speaker Labeling" : task.kind.rawValue.capitalized
            subtitle.stringValue = kind + " · " + task.state.rawValue.capitalized
        case .voice(let job):
            title.stringValue = job.discover ? "Find Voices" : "Prepare Voice Library"
            subtitle.stringValue = job.providerName + " · " + job.state.rawValue.capitalized
        }
        setAccessibilityLabel(title.stringValue + ", " + subtitle.stringValue)
    }
}
