import AppKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @ObservedObject var session: LibrarySearchSession
    @Binding var mode: SearchMode
    var open: (SearchDisplayResult) -> Void
    var retry: () -> Void
    var openPerson: (UUID) -> Void = { _ in }

    private var footerText: String? {
        guard !session.isLoading, session.error == nil, !session.canLoadMore,
            !session.displayResults.isEmpty, let total = session.total
        else { return nil }
        if session.usesRankedSearch {
            return ListCountFooter.text(
                count: session.displayResults.count, singular: "Result Shown", plural: "Results Shown")
        }
        return ListCountFooter.text(count: total, singular: "Match", plural: "Matches")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("“\(session.query)”").font(.headline).textSelection(.enabled)
                    Spacer()
                    SearchModePicker(selection: $mode)
                }
                if let message = session.peopleError {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if !session.peopleResolution.candidates.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            peopleSection("People Matches", candidates: session.peopleResolution.confident)
                            peopleSection(
                                "People Suggestions",
                                candidates: session.peopleResolution.candidates.filter { !$0.isConfident })
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 176)
                }
                if !session.contentQuery.isEmpty {
                    Text("Content Results").font(.headline)
                    if session.contentQuery != session.query {
                        Text("Topic: \(session.contentQuery)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let total = session.total, !session.contentQuery.isEmpty {
                    Text(
                        (session.usesRankedSearch ? "Top " : "")
                            + "\(total.formatted()) \(total == 1 ? "match" : "matches")"
                    )
                    .foregroundStyle(.secondary).font(.callout)
                }
            }.padding(AppTheme.contentInset)
            if session.error == nil, !session.providerFailures.isEmpty {
                HStack {
                    Text(session.providerFailures.values.sorted().joined(separator: " "))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again", action: retry)
                }.padding(.horizontal, AppTheme.contentInset).padding(.bottom, AppTheme.contentSpacing)
            }
            NativeSearchResults(
                session: session, results: session.displayResults, generation: session.generation,
                footerText: footerText, open: open
            )
            .overlay {
                if session.isLoading && session.displayResults.isEmpty {
                    ProgressView("Searching…")
                }
                else if session.total == 0 && session.error == nil && !session.contentQuery.isEmpty {
                    ContentUnavailableView.search(text: session.contentQuery)
                }
                else if let error = session.error, session.displayResults.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again", action: retry)
                    }
                }
            }
            if !session.displayResults.isEmpty {
                HStack {
                    Text("Double-click a result or press Return to open it.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.isLoading { ProgressView().controlSize(.small) }
                    if let error = session.error {
                        Text(error).font(.callout)
                        Button("Try Again", action: retry)
                    }
                }.padding(AppTheme.contentSpacing)
            }
        }
        .background(AppTheme.readingBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func peopleSection(_ title: String, candidates: [PeopleNameCandidate]) -> some View {
        if !candidates.isEmpty {
            Text(title).font(.headline)
            ForEach(candidates) { candidate in
                Button {
                    openPerson(candidate.personID)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(candidate.name).font(.body)
                        Text("Matched “\(candidate.matchedPhrase)”").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(candidate.name)")
                .accessibilityHint(candidate.isConfident ? "People name match" : "Possible People name match")
            }
            ListCountFooter(text: ListCountFooter.text(count: candidates.count, singular: "Person", plural: "People"))
        }
    }

}

/// Reusable native cells retain a pixel viewport and selection when returning from a meeting.
private struct NativeSearchResults: NSViewRepresentable {
    let session: LibrarySearchSession
    let results: [SearchDisplayResult]
    let generation: UUID
    let footerText: String?
    let open: (SearchDisplayResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = SearchResultsTable()
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 78
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.activate = { [weak coordinator = context.coordinator] in coordinator?.activate() }
        table.setAccessibilityLabel("Search Results")
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
        var parent: NativeSearchResults
        weak var table: SearchResultsTable?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var rows: [SearchDisplayResult] = []
        var generation: UUID?
        var updating = false
        var announced = false
        init(_ parent: NativeSearchResults) { self.parent = parent }
        func update(_ value: NativeSearchResults) {
            guard let table, let scroll else { return }
            updating = true
            let footerChanged = parent.footerText != value.footerText
            parent = value
            let reset = generation != value.generation
            if reset { announced = false }
            generation = value.generation
            if rows != value.results || reset || footerChanged {
                let offset = value.session.scrollOffset
                rows = value.results
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                if let selection = value.session.selection, let row = rows.firstIndex(where: { $0.id == selection }) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                else {
                    table.deselectAll(nil)
                }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            updating = false
            if !value.session.isLoading, value.session.error == nil, !announced, let total = value.session.total {
                announced = true
                if total > 0 {
                    let generation = value.generation
                    let session = value.session
                    DispatchQueue.main.async { [weak table] in
                        guard generation == session.generation, !session.isLoading,
                            let table, let window = table.window
                        else { return }
                        window.makeFirstResponder(table)
                    }
                }
                NSAccessibility.post(
                    element: NSApplication.shared, notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Search complete. \(total) \(total == 1 ? "match" : "matches").",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
            }
            scrolled()
        }
        func scrolled() {
            guard !updating, let table, let scroll else { return }
            parent.session.scrollOffset = scroll.contentView.bounds.minY
            let visible = table.rows(in: scroll.contentView.bounds)
            if visible.location != NSNotFound && NSMaxRange(visible) >= rows.count - 10 {
                let session = parent.session
                Task { @MainActor in session.loadMore() }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (parent.footerText == nil ? 0 : 1) }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows.indices.contains(row) ? 78 : 40
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.session.selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        }
        @objc func activate() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            parent.open(rows[table.selectedRow])
        }
        @objc func doubleClicked() {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            parent.open(rows[table.clickedRow])
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == rows.count, let text = parent.footerText {
                return NativeListCountCell.make(in: tableView, text: text)
            }
            let identifier = NSUserInterfaceItemIdentifier("search-result")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultCell ?? SearchResultCell()
            cell.identifier = identifier
            cell.configure(rows[row])
            return cell
        }
    }
}

private final class SearchResultsTable: NSTableView {
    var activate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            activate?()
        }
        else {
            super.keyDown(with: event)
        }
    }
}

private final class SearchResultCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let metadata = NSTextField(labelWithString: "")
    let excerpt = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        metadata.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        metadata.textColor = .secondaryLabelColor
        excerpt.font = .systemFont(ofSize: NSFont.systemFontSize)
        for field in [title, metadata, excerpt] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ])
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            excerpt.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 5),
        ])
        textField = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ result: SearchDisplayResult) {
        title.stringValue = result.title
        let source: String
        switch result.passage?.kind {
        case .title: source = "Meeting"
        case .notes: source = "Notes"
        case .summary: source = "Summary"
        case .transcript: source = "Transcript · " + playbackTime(result.passage?.start ?? 0)
        case nil: source = "Voice · " + playbackTime(result.audio?.start ?? 0)
        }
        metadata.stringValue = [result.createdAt?.formatted(date: .abbreviated, time: .shortened), source].compactMap {
            $0
        }.joined(separator: " · ")
        excerpt.stringValue = result.excerpt.replacingOccurrences(of: "\n", with: " ")
        setAccessibilityLabel([title.stringValue, metadata.stringValue, excerpt.stringValue].joined(separator: ". "))
        toolTip = result.excerpt
    }
}
