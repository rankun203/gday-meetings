import AppKit
import SwiftUI

enum LibraryDestination: Int, CaseIterable, Hashable {
    case meetings, people, tags, tasks, agents
    var title: String { ["Meetings", "People", "Tags", "Tasks", "Agents"][rawValue] }
    var symbol: String {
        ["waveform", "person.2", "tag", "list.bullet.rectangle", "bubble.left.and.text.bubble.right"][rawValue]
    }
}

struct NativeLibrarySidebar: NSViewRepresentable {
    @Binding var selection: LibraryDestination?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.style = .sourceList
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Sidebar")
        table.addTableColumn(NSTableColumn(identifier: .init("destination")))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        table.reloadData()
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeLibrarySidebar
        weak var table: NSTableView?
        private var updating = false
        init(_ parent: NativeLibrarySidebar) { self.parent = parent }
        func update(_ parent: NativeLibrarySidebar) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }
            let selected = parent.selection.map { IndexSet(integer: $0.rawValue) } ?? IndexSet()
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { LibraryDestination.allCases.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LibrarySidebarRow()
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let destination = LibraryDestination(rawValue: row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("sidebarDestination")
            let cell =
                (tableView.makeView(withIdentifier: id, owner: self) as? LibrarySidebarCell) ?? LibrarySidebarCell()
            cell.identifier = id
            cell.configure(destination)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            publishSelection()
        }
        private func publishSelection() {
            guard !updating, let table, let destination = LibraryDestination(rawValue: table.selectedRow),
                parent.selection != destination
            else {
                return
            }
            parent.selection = destination
        }
    }
}

@MainActor final class LibrarySidebarRow: NSTableRowView {
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        isHovered =
            window.map {
                $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
            } ?? false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected, window?.isKeyWindow == true else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor private final class LibrarySidebarCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        for view in [icon, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ destination: LibraryDestination) {
        textField?.stringValue = destination.title
        imageView?.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
        setAccessibilityLabel(destination.title)
    }
}
