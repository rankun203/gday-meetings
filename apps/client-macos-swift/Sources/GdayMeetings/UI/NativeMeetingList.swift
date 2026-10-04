import AppKit
import SwiftUI

/// Native row reuse and pixel anchoring keep cursor-window rotation independent of scrolling.
struct NativeMeetingList: NSViewRepresentable {
    var entries: [MeetingListEntry]
    @Binding var selection: UUID?
    var revealID: UUID?
    var recordingID: UUID?
    var isFinalizing: Bool
    var playingID: UUID?
    var isPlaying: Bool
    var canPlay: Bool
    var archiveStatuses: [UUID: MeetingArchiveStatus]
    var displaySummaryTitle = true
    var viewportChanged: (MeetingViewport) -> Void
    var play: (UUID) -> Void
    var reveal: (UUID) -> Void
    var export: (UUID) -> Void
    var delete: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = MeetingNativeTable()
        table.autoresizingMask = [.width]
        table.style = .inset
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Meetings")
        let column = NSTableColumn(identifier: .init("meeting"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.deleteSelected = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.requestDeletion(row: coordinator.table?.selectedRow ?? -1)
        }
        table.menuForRow = { [weak coordinator = context.coordinator] in coordinator?.menu(row: $0) }
        table.revealRow = { [weak coordinator = context.coordinator] row in
            guard let coordinator, coordinator.rows.indices.contains(row) else { return }
            coordinator.parent.reveal(coordinator.rows[row].id)
        }
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.viewportDidChange() }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeMeetingList
        weak var table: MeetingNativeTable?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        private(set) var rows: [MeetingListEntry] = []
        private var updating = false
        private var scheduledViewport = false
        private var revealed: UUID?
        private var lastOffset: CGFloat = 0
        private var lastTime = ProcessInfo.processInfo.systemUptime
        private var velocity: Double = 0

        init(_ parent: NativeMeetingList) { self.parent = parent }
        func update(_ value: NativeMeetingList) {
            guard let table, let scroll else { return }
            let range = table.rows(in: scroll.contentView.bounds)
            let anchorIndex = range.location
            let anchor = rows.indices.contains(anchorIndex) ? rows[anchorIndex].id : nil
            let offset = anchor.map { _ in scroll.contentView.bounds.minY - table.rect(ofRow: anchorIndex).minY } ?? 0
            let changed = rows != value.entries || parent.displaySummaryTitle != value.displaySummaryTitle
            let appearanceChanged =
                parent.recordingID != value.recordingID || parent.isFinalizing != value.isFinalizing
                || parent.playingID != value.playingID || parent.isPlaying != value.isPlaying
                || parent.archiveStatuses != value.archiveStatuses
            parent = value
            updating = true
            if changed {
                rows = value.entries
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                if let anchor, let row = rows.firstIndex(where: { $0.id == anchor }) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            else if appearanceChanged {
                let visible = table.rows(in: scroll.contentView.bounds)
                if visible.location != NSNotFound, visible.length > 0 {
                    table.reloadData(
                        forRowIndexes: IndexSet(integersIn: visible.location..<min(rows.count, NSMaxRange(visible))),
                        columnIndexes: IndexSet(integer: 0))
                }
            }
            if let selected = value.selection, let row = rows.firstIndex(where: { $0.id == selected }) {
                if table.selectedRow != row {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
            else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
            if let revealID = value.revealID, revealed != revealID,
                let row = rows.firstIndex(where: { $0.id == revealID })
            {
                table.scrollRowToVisible(row)
                if row == 0 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                revealed = revealID
            }
            lastOffset = scroll.contentView.bounds.minY
            lastTime = ProcessInfo.processInfo.systemUptime
            updating = false
            scheduleViewport()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            MeetingSummaryPreview.rowHeight(rows[row].summary, enabled: parent.displaySummaryTitle)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("meeting-row")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? MeetingNativeCell ?? MeetingNativeCell()
            cell.identifier = identifier
            let entry = rows[row]
            var symbol: String?
            var status = ""
            var color = NSColor.controlAccentColor
            if parent.recordingID == entry.id {
                symbol = parent.isFinalizing ? "externaldrive" : "record.circle"
                status = parent.isFinalizing ? "Saving audio" : "Recording"
                color = parent.isFinalizing ? .secondaryLabelColor : .systemRed
            }
            else if parent.playingID == entry.id {
                symbol = parent.isPlaying ? "speaker.wave.2.fill" : "pause.circle"
                status = parent.isPlaying ? "Playing" : "Playback paused"
            }
            cell.configure(
                entry, symbol: symbol, status: status, color: color, archive: parent.archiveStatuses[entry.id],
                displaySummaryTitle: parent.displaySummaryTitle)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("meeting-selection-row")
            let view =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? MeetingSelectionRow
                ?? MeetingSelectionRow()
            view.identifier = identifier
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        }
        @objc func doubleClicked(_ sender: NSTableView) {
            guard parent.canPlay, rows.indices.contains(sender.clickedRow) else { return }
            parent.play(rows[sender.clickedRow].id)
        }
        func viewportDidChange() {
            guard !updating, let scroll else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let dt = now - lastTime
            if dt > 0.002 {
                let current = Double(scroll.contentView.bounds.minY - lastOffset) / dt / 60
                velocity = velocity * 0.35 + current * 0.65
            }
            lastOffset = scroll.contentView.bounds.minY
            lastTime = now
            scheduleViewport()
        }
        private func scheduleViewport() {
            guard !scheduledViewport else { return }
            scheduledViewport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledViewport = false
                guard let table = self.table, let scroll = self.scroll else { return }
                let range = table.rows(in: scroll.contentView.bounds)
                guard range.location != NSNotFound, range.length > 0, self.rows.indices.contains(range.location) else {
                    return
                }
                let last = min(self.rows.count - 1, NSMaxRange(range) - 1)
                self.parent.viewportChanged(
                    .init(
                        firstID: self.rows[range.location].id, lastID: self.rows[last].id,
                        visibleCount: last - range.location + 1, rowsPerSecond: self.velocity))
            }
        }
        func menu(row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row]
            let menu = NSMenu()
            if !entry.audioFiles.isEmpty {
                let item = NSMenuItem(title: "Play", action: #selector(playItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.isEnabled = parent.canPlay
                menu.addItem(item)
            }
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealItem(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = entry.id
            menu.addItem(reveal)
            let export = NSMenuItem(title: "Export Meeting…", action: #selector(exportItem(_:)), keyEquivalent: "")
            export.target = self
            export.representedObject = entry.id
            menu.addItem(export)
            let delete = NSMenuItem(title: "Move to Trash…", action: #selector(deleteItem(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = entry.id
            delete.isEnabled = parent.recordingID != entry.id
            menu.addItem(delete)
            menu.autoenablesItems = false
            return menu
        }
        @objc private func playItem(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID { parent.play(id) }
        }
        @objc private func revealItem(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID { parent.reveal(id) }
        }
        @objc private func exportItem(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID { parent.export(id) }
        }
        func requestDeletion(row: Int) {
            guard rows.indices.contains(row), rows[row].id != parent.recordingID else { return }
            parent.delete(rows[row].id)
        }
        @objc private func deleteItem(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID { parent.delete(id) }
        }
    }
}

final class MeetingNativeTable: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    var deleteSelected: (() -> Void)?
    var revealRow: ((Int) -> Void)?
    private var cursorTracking: NSTrackingArea?
    private var modifierMonitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        super.viewWillMove(toWindow: newWindow)
        if newWindow != nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow else { return event }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.visibleRect.contains(point) {
                    self.updatePointer(at: point, modifiers: event.modifierFlags)
                }
                return event
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        cursorTracking = area
        addTrackingArea(area)
    }

    func updatePointer(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let canReveal = visibleRect.contains(point) && row(at: point) >= 0 && modifiers.contains(.command)
        (canReveal ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command), clickedRow >= 0 {
            if event.clickCount == 1 { revealRow?(clickedRow) }
            return
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        {
            deleteSelected?()
        }
        else {
            super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return menuForRow?(row)
    }
}

final class MeetingNativeCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let statusImage = NSImageView()
    private let archiveImage = NSImageView()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        dateLabel.font = .systemFont(ofSize: 10)
        summaryLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .secondaryLabelColor
        summaryLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        dateLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail
        for view in [titleLabel, dateLabel, summaryLabel, statusImage, archiveImage] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(
        _ entry: MeetingListEntry, symbol: String?, status: String, color: NSColor, archive: MeetingArchiveStatus?,
        displaySummaryTitle: Bool = true
    ) {
        titleLabel.stringValue = entry.title
        dateLabel.stringValue =
            entry.createdAt.formatted(.dateTime.month().day().hour().minute())
            + (entry.duration > 0 ? " · " + playbackTime(entry.duration) : "")
        summaryLabel.stringValue = displaySummaryTitle ? MeetingSummaryPreview.text(entry.summary) : ""
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty
        statusImage.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: status) }
        statusImage.contentTintColor = color
        statusImage.isHidden = symbol == nil
        archiveImage.image = archive.flatMap {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.accessibilityText)
        }
        archiveImage.contentTintColor = .secondaryLabelColor
        archiveImage.isHidden = archive == nil
        archiveImage.toolTip = archive?.title
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let width = max(0, bounds.width - inset * 2)
        titleLabel.frame = NSRect(x: inset, y: 5, width: width - (statusImage.isHidden ? 0 : 22), height: 18)
        statusImage.frame = NSRect(x: bounds.width - inset - 16, y: 6, width: 16, height: 16)
        dateLabel.frame = NSRect(x: inset, y: 25, width: width - (archiveImage.isHidden ? 0 : 20), height: 14)
        archiveImage.frame = NSRect(x: bounds.width - inset - 16, y: 24, width: 16, height: 16)
        summaryLabel.frame = NSRect(x: inset, y: 43, width: width, height: max(0, bounds.height - 49))
    }
}

@MainActor enum MeetingSummaryPreview {
    static func text(_ source: String) -> String {
        let firstLine = source.prefix { !$0.isNewline }
        return String(firstLine.drop { $0 == "#" || $0.isWhitespace })
            .trimmingCharacters(in: .whitespaces)
    }
    static func rowHeight(_ source: String, enabled: Bool = true) -> CGFloat {
        enabled && !text(source).isEmpty ? 62 : 48
    }
}

/// Keep selection quiet without replacing the native table's focus and selection semantics.
final class MeetingSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.labelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
