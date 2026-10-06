import AppKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @ObservedObject var session: LibrarySearchSession
    @Binding var mode: SearchMode
    var open: (SearchDisplayResult) -> Void
    var retry: () -> Void
    var openPerson: (UUID) -> Void = { _ in }

    var play: (SearchDisplayResult) -> Void = { _ in }
    var canPlay = true
    var index: LibraryIndex?
    @AppStorage("showSearchRankingDetails") private var showRankingDetails = false
    @ViewState private var summaries: [UUID: String] = [:]
    @ViewState private var playableMeetings: Set<UUID> = []

    private var matchedPeople: [PeopleNameCandidate] {
        session.peopleResolution.candidates.filter { session.peopleResolution.unambiguousPeople.contains($0.personID) }
    }
    private var possiblePeople: [PeopleNameCandidate] {
        session.peopleResolution.candidates.filter { !session.peopleResolution.unambiguousPeople.contains($0.personID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.total.map { "\($0.formatted()) \($0 == 1 ? "result" : "results")" } ?? "Searching…")
                        .font(.headline)
                    if session.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Show Ranking Details", isOn: $showRankingDetails).toggleStyle(.checkbox)
                        .disabled(session.mode != .semantic || !session.usesRankedSearch)
                    SearchModePicker(selection: $mode)
                }
                if !matchedPeople.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        peopleRow(matchedPeople, limit: 4)
                        peopleRow(matchedPeople, limit: 1)
                    }
                }
                if !possiblePeople.isEmpty {
                    DisclosureGroup("Possible Matches (\(possiblePeople.count))") {
                        Text("These names do not affect ranking.").font(.caption).foregroundStyle(.secondary)
                        peopleRow(possiblePeople, limit: 3)
                    }.font(.callout)
                }
                if let message = session.peopleError { Text(message).foregroundStyle(.secondary) }
                if session.error == nil, !session.providerFailures.isEmpty {
                    HStack {
                        Text(session.providerFailures.values.sorted().joined(separator: " ")).font(.callout)
                        Button("Try Again", action: retry)
                    }
                }
            }.padding(AppTheme.contentInset)
            NativeSearchResults(
                session: session, results: session.displayResults, generation: session.generation,
                showRankingDetails: showRankingDetails, summaries: summaries, playableMeetings: playableMeetings,
                canPlay: canPlay,
                open: open, play: play
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
            if let error = session.error, !session.displayResults.isEmpty {
                HStack {
                    Text(error)
                    Button("Try Again", action: retry)
                }.padding(AppTheme.contentSpacing)
            }
        }
        .background(AppTheme.readingBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.displayResults.map(\.meetingID)) {
            let ids = Set(session.displayResults.map(\.meetingID))
            let index = index
            let values = await Task.detached(priority: .utility) {
                var values: [UUID: MeetingListEntry] = [:]
                for id in ids {
                    if let entry = try? index?.entry(id: id) { values[id] = entry }
                }
                return values
            }.value
            if !Task.isCancelled {
                summaries = values.mapValues { MeetingSummaryPreview.text($0.summary) }
                playableMeetings = Set(values.values.filter { !$0.audioFiles.isEmpty }.map(\.id))
            }
        }
    }

    private func peopleRow(_ candidates: [PeopleNameCandidate], limit: Int) -> some View {
        HStack(spacing: 6) {
            Text("People:").font(.callout).foregroundStyle(.secondary)
            ForEach(candidates.prefix(limit)) { candidate in
                let tint = TranscriptSpeakerPalette.color(for: candidate.personID.uuidString)
                Button {
                    openPerson(candidate.personID)
                } label: {
                    Text(candidate.name).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
                        .background(Color(nsColor: tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                    .help(
                        "Matched “\(candidate.matchedPhrase)”. "
                            + (session.peopleResolution.unambiguousPeople.contains(candidate.personID)
                                ? "Passages spoken by this person receive the speaker match boost."
                                : "This possible match does not affect ranking.")
                    )
                    .accessibilityLabel("Open \(candidate.name)")
            }
            if candidates.count > limit {
                Menu("+\(candidates.count - limit)") {
                    ForEach(candidates.dropFirst(limit)) { candidate in
                        Button(candidate.name) { openPerson(candidate.personID) }
                    }
                }.fixedSize()
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

/// Reusable native cells retain a pixel viewport and selection when returning from a meeting.
private struct NativeSearchResults: NSViewRepresentable {
    let session: LibrarySearchSession
    let results: [SearchDisplayResult]
    let generation: UUID
    let showRankingDetails: Bool
    let summaries: [UUID: String]
    let playableMeetings: Set<UUID>
    let canPlay: Bool
    let open: (SearchDisplayResult) -> Void
    let play: (SearchDisplayResult) -> Void

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
        table.rowHeight = 96
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
            let presentationChanged =
                parent.showRankingDetails != value.showRankingDetails || parent.summaries != value.summaries
                || parent.canPlay != value.canPlay
            parent = value
            let reset = generation != value.generation
            if reset { announced = false }
            generation = value.generation
            if rows != value.results || reset || presentationChanged {
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
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.showRankingDetails && rows[row].scoreBreakdown != nil ? 118 : 96
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
            let identifier = NSUserInterfaceItemIdentifier("search-result")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultCell ?? SearchResultCell()
            cell.identifier = identifier
            let result = rows[row]
            cell.configure(
                result, summary: parent.summaries[result.meetingID], showScore: parent.showRankingDetails,
                canPlay: parent.canPlay && parent.playableMeetings.contains(result.meetingID))
            cell.open = { [weak self] in
                self?.parent.session.selection = result.id
                self?.parent.open(result)
            }
            cell.play = { [weak self] in self?.parent.play(result) }
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
    let summary = NSTextField(labelWithString: "")
    let excerpt = NSTextField(wrappingLabelWithString: "")
    let score = NSTextField(labelWithString: "")
    let playButton = NSButton(title: "Play", target: nil, action: nil)
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    var open: (() -> Void)?
    var play: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for field in [metadata, summary, score] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        excerpt.font = .systemFont(ofSize: NSFont.systemFontSize)
        for field in [title, metadata, summary, excerpt, score] {
            field.lineBreakMode = field === excerpt ? .byWordWrapping : .byTruncatingTail
            field.maximumNumberOfLines = field === excerpt ? 2 : 1
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        for button in [playButton, openButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            addSubview(button)
        }
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.action = #selector(playResult)
        openButton.action = #selector(openResult)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: metadata.leadingAnchor, constant: -16),
            metadata.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -16),
            metadata.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            openButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            openButton.widthAnchor.constraint(equalToConstant: 64),
            playButton.trailingAnchor.constraint(equalTo: openButton.trailingAnchor),
            playButton.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 6),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            summary.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -16),
            excerpt.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            excerpt.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 5),
            excerpt.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -16),
            excerpt.heightAnchor.constraint(equalToConstant: 36),
            score.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            score.trailingAnchor.constraint(equalTo: excerpt.trailingAnchor),
            score.topAnchor.constraint(equalTo: excerpt.bottomAnchor, constant: 4),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openResult() { open?() }
    @objc private func playResult() { play?() }
    func configure(_ result: SearchDisplayResult, summary summaryTitle: String?, showScore: Bool, canPlay: Bool) {
        title.stringValue = result.title
        metadata.stringValue = result.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let source: String
        switch result.passage?.kind {
        case .title: source = "Meeting"
        case .notes: source = "Notes"
        case .summary: source = "Summary"
        case .transcript: source = "Transcript · " + playbackTime(result.passage?.start ?? 0)
        case nil: source = "Audio · " + playbackTime(result.audio?.start ?? 0)
        }
        summary.stringValue = [source, summaryTitle?.isEmpty == false ? summaryTitle : nil].compactMap { $0 }.joined(
            separator: " · ")
        score.stringValue = showScore ? result.scoreBreakdown?.description ?? "" : ""
        score.isHidden = !showScore || result.scoreBreakdown == nil
        excerpt.stringValue = result.excerpt.replacingOccurrences(of: "\n", with: " ")
        let start = result.passage?.start ?? result.audio?.start
        playButton.isHidden = start == nil
        playButton.isEnabled = canPlay && start != nil
        playButton.toolTip =
            canPlay
            ? start.map { "Play from " + playbackTime($0) }
            : "Playback is unavailable while recording or when this meeting has no audio."
        playButton.setAccessibilityLabel("Play \(result.title) from \(playbackTime(start ?? 0))")
        openButton.setAccessibilityLabel("Open \(result.title)")
        openButton.toolTip = "Open this passage in the meeting"
        toolTip = result.excerpt
    }
}
