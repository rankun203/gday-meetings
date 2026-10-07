import AppKit
import SwiftUI

struct NativeTaskList: NSViewRepresentable {
    let rows: [TaskHistoryRow]
    @Binding var selection: UUID?
    var recordingActive = false
    var revealID: UUID?
    var revealToken: UUID? = nil
    var retainedViewport: NativeListViewport? = nil
    var totalCount: Int? = nil
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
        table.rowHeight = 84
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
        init(_ parent: NativeTaskList) {
            self.parent = parent
            revealed = parent.retainedViewport?.revealedID
        }
        func update(_ value: NativeTaskList) {
            guard let table, let scroll else { return }
            let first = table.rows(in: scroll.contentView.bounds).location
            let anchor = rows.indices.contains(first) ? rows[first].id : value.retainedViewport?.anchor?.id
            let delta =
                rows.indices.contains(first)
                ? scroll.contentView.bounds.minY - table.rect(ofRow: first).minY
                : value.retainedViewport?.anchor?.offset ?? 0
            updating = true
            let sameIDs = rows.map(\.id) == value.rows.map(\.id)
            let sameCount = parent.totalCount == value.totalCount
            let sameFooter = (parent.totalCount == nil) == (value.totalCount == nil)
            let recordingChanged = parent.recordingActive != value.recordingActive
            let changed = rows != value.rows || parent.totalCount != value.totalCount || recordingChanged
            var changedIndices = IndexSet(
                rows.indices.filter { index in
                    guard value.rows.indices.contains(index) else { return false }
                    if rows[index] != value.rows[index] { return true }
                    guard recordingChanged else { return false }
                    if case .managed(let task) = rows[index] {
                        return [.searchIndex, .diarization].contains(task.kind) && task.state == .queued
                    }
                    return false
                })
            if !sameCount, sameFooter, value.totalCount != nil { changedIndices.insert(value.rows.count) }
            parent = value
            if changed {
                rows = value.rows
                if sameIDs && sameFooter {
                    table.reloadData(
                        forRowIndexes: changedIndices,
                        columnIndexes: IndexSet(integer: 0))
                }
                else {
                    table.reloadData()
                }
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
            if let id = value.revealID, revealed != (value.revealToken ?? id),
                let position = rows.firstIndex(where: { $0.id == id })
            {
                table.scrollRowToVisible(position)
                revealed = value.revealToken ?? id
                value.retainedViewport?.revealedID = revealed
            }
            offset = scroll.contentView.bounds.minY
            updating = false
            rememberViewport()
            if rows.count <= 50 { report(newer: false) }
        }
        func scrolled() {
            if !updating { rememberViewport() }
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
        private func rememberViewport() {
            guard let table, let scroll, let retained = parent.retainedViewport else { return }
            let first = table.rows(in: scroll.contentView.bounds).location
            guard rows.indices.contains(first) else { return }
            retained.anchor = .init(
                id: rows[first].id, offset: scroll.contentView.bounds.minY - table.rect(ofRow: first).minY)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (parent.totalCount == nil ? 0 : 1) }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows.indices.contains(row) ? 84 : 40
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            rows.indices.contains(row) ? MeetingSelectionRow() : NSTableRowView()
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow) else { return }
            parent.selection = rows[table.selectedRow].id
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == rows.count, let count = parent.totalCount {
                return NativeListCountCell.make(
                    in: tableView,
                    text: ListCountFooter.text(count: count, singular: "Task", plural: "Tasks"))
            }
            let identifier = NSUserInterfaceItemIdentifier("task-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TaskCell ?? TaskCell()
            cell.identifier = identifier
            cell.configure(rows[row], recordingActive: parent.recordingActive)
            return cell
        }
    }
}

private final class TaskCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for label in [title, subtitle, detail] {
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
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 5),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: TaskHistoryRow, recordingActive: Bool) {
        let description = TaskDescription(row, recordingActive: recordingActive)
        title.stringValue = description.operation + " · " + description.affectedItem
        subtitle.stringValue = description.progress
        subtitle.textColor = description.attention ? .labelColor : .secondaryLabelColor
        detail.stringValue =
            description.state + " · " + description.date.formatted(date: .abbreviated, time: .shortened)
        setAccessibilityLabel(title.stringValue + ", " + subtitle.stringValue + ", " + detail.stringValue)
    }
}
