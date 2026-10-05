import AppKit
import SwiftUI

enum LibraryDestination: Int, CaseIterable, Hashable {
    case meetings, people, tags, tasks, agents
    var title: String { ["Meetings", "People", "Tags", "Tasks", "Agents"][rawValue] }
    var symbol: String {
        ["waveform", "person.2", "tag", "list.bullet.rectangle", "bubble.left.and.text.bubble.right"][rawValue]
    }
    var usesTwoColumns: Bool { self == .tasks || self == .agents }
}

/// An explicit user selection may replace the split's sidebar. Only its new
/// native table can consume this request; ordinary updates never request focus.
@MainActor final class LibrarySidebarFocusRequest: ObservableObject {
    private var pending: (destination: LibraryDestination, origin: UUID)?
    func request(_ destination: LibraryDestination, origin: UUID) { pending = (destination, origin) }
    func cancel() { pending = nil }
    func cancelIfDestinationChanged(to destination: LibraryDestination?, instance: UUID? = nil) {
        // SwiftUI may update the departing column with its old selection while
        // building the replacement. That origin cannot cancel its own transfer.
        if let pending, pending.origin != instance, pending.destination != destination { self.pending = nil }
    }
    func matches(_ destination: LibraryDestination?, instance: UUID) -> Bool {
        guard let pending else { return false }
        return pending.origin != instance && pending.destination == destination
    }
    func consume(for destination: LibraryDestination?, instance: UUID) -> Bool {
        guard let pending, pending.origin != instance else { return false }
        self.pending = nil
        return pending.destination == destination
    }
}

struct NativeLibrarySidebar: NSViewRepresentable {
    @Binding var selection: LibraryDestination?
    let twoColumn: Bool
    let focusRequest: LibrarySidebarFocusRequest

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = LibrarySidebarTable()
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
        table.focusRequest = focusRequest
        table.destination = selection
        scroll.documentView = table
        context.coordinator.table = table
        table.reloadData()
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeLibrarySidebar
        weak var table: LibrarySidebarTable?
        private var updating = false
        init(_ parent: NativeLibrarySidebar) { self.parent = parent }
        func update(_ parent: NativeLibrarySidebar) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }
            parent.focusRequest.cancelIfDestinationChanged(to: parent.selection, instance: table.instanceID)
            table.destination = parent.selection
            let selected = parent.selection.map { IndexSet(integer: $0.rawValue) } ?? IndexSet()
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { LibraryDestination.allCases.count }
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
            guard !updating, let table, let destination = LibraryDestination(rawValue: table.selectedRow) else {
                return
            }
            if parent.twoColumn != destination.usesTwoColumns {
                parent.focusRequest.request(destination, origin: table.instanceID)
            }
            else {
                parent.focusRequest.cancel()
            }
            parent.selection = destination
        }
    }
}

@MainActor final class LibrarySidebarTable: NSTableView {
    let instanceID = UUID()
    var destination: LibraryDestination?
    weak var focusRequest: LibrarySidebarFocusRequest?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let previousResponder = window.firstResponder
        // The split finishes dismantling its old column after mounting this
        // table. Transfer once after that transaction, not during the mount.
        DispatchQueue.main.async { [weak self, weak window, weak previousResponder] in
            guard let self, let window, self.window === window,
                let request = self.focusRequest, request.matches(self.destination, instance: self.instanceID)
            else { return }
            guard !self.isHiddenOrHasHiddenAncestor,
                window.firstResponder === window || window.firstResponder === previousResponder
                    || window.firstResponder === self
            else {
                request.cancel()
                return
            }
            if window.makeFirstResponder(self) {
                _ = request.consume(for: self.destination, instance: self.instanceID)
            }
            else {
                request.cancel()
            }
        }
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
