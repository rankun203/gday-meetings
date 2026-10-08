import AppKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @ObservedObject var session: LibrarySearchSession
    var open: (SearchDisplayResult) -> Void
    var retry: () -> Void
    var openPerson: (UUID) -> Void = { _ in }

    var play: (SearchDisplayResult) -> Void = { _ in }
    var navigate: (SearchDisplayResult) -> Void = { _ in }
    var selectMatch: (SearchDisplayResult) -> Void = { _ in }
    var canPlay = true
    var index: LibraryIndex?
    @AppStorage("showSearchRankingDetails") private var showRankingDetails = false
    @ViewState private var summaries: [UUID: String] = [:]
    @ViewState private var playableMeetings: Set<UUID> = []
    @ViewState private var timelines: [String: SearchResultTimeline] = [:]

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
                    Text(session.total.map { "\($0.formatted()) \($0 == 1 ? "match" : "matches")" } ?? "Searching…")
                        .font(.headline)
                    if session.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Show Ranking Details", isOn: $showRankingDetails).toggleStyle(.checkbox)
                        .disabled(session.mode != .semantic || !session.usesRankedSearch)
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
                .frame(maxWidth: .infinity)
            NativeSearchResults(
                session: session, results: session.displayResults, generation: session.generation,
                showRankingDetails: showRankingDetails, summaries: summaries, playableMeetings: playableMeetings,
                canPlay: canPlay, timelines: timelines, activeMatches: session.activeMatches,
                open: open, play: play, navigate: navigate, selectMatch: selectMatch
            )
            .frame(maxWidth: .infinity)
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
        .task(id: session.displayResults) {
            let results = session.displayResults
            let ids = Set(results.map(\.meetingID))
            let index = index
            let values = await Task.detached(priority: .utility) {
                var values: [UUID: MeetingListEntry] = [:]
                for id in ids {
                    if let entry = try? index?.entry(id: id) { values[id] = entry }
                }
                var timelines: [String: SearchResultTimeline] = [:]
                for result in results {
                    guard let entry = values[result.meetingID] else { continue }
                    timelines[result.id] = result.timeline(duration: entry.duration)
                }
                return (values, timelines)
            }.value
            if !Task.isCancelled {
                timelines = values.1
                summaries = values.0.mapValues { MeetingSummaryPreview.text($0.summary) }
                playableMeetings = Set(values.0.values.filter { !$0.audioFiles.isEmpty }.map(\.id))
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
    let timelines: [String: SearchResultTimeline]
    let activeMatches: [UUID: String]
    let open: (SearchDisplayResult) -> Void
    let play: (SearchDisplayResult) -> Void
    let navigate: (SearchDisplayResult) -> Void
    let selectMatch: (SearchDisplayResult) -> Void

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
        table.rowHeight = 100
        table.usesAutomaticRowHeights = false
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
        table.action = #selector(Coordinator.clicked)
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
        var rows: [SearchResultGroup] = []
        var generation: UUID?
        var updating = false
        var announced = false
        private var resizeReloadPending = false
        private var renderedMatches: [UUID: String] = [:]
        private let measurementCell = SearchResultCell()
        init(_ parent: NativeSearchResults) { self.parent = parent }
        func update(_ value: NativeSearchResults) {
            guard let table, let scroll else { return }
            updating = true
            let presentationChanged =
                parent.showRankingDetails != value.showRankingDetails || parent.summaries != value.summaries
                || parent.canPlay != value.canPlay || parent.playableMeetings != value.playableMeetings
                || parent.timelines != value.timelines || renderedMatches != value.activeMatches
            parent = value
            renderedMatches = value.activeMatches
            let reset = generation != value.generation
            if reset {
                announced = false
            }
            generation = value.generation
            let groups = SearchResultGroup.grouping(value.results)
            if rows != groups || reset || presentationChanged {
                let offset = value.session.scrollOffset
                rows = groups
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                if let selection = value.session.selection,
                    let row = rows.firstIndex(where: { $0.matches.contains { $0.id == selection } })
                {
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
        func tableViewColumnDidResize(_ notification: Notification) {
            guard !resizeReloadPending else { return }
            resizeReloadPending = true
            // Finish AppKit's resize, then restore the current result identity rather than an old row index.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.resizeReloadPending = false }
                guard let table = self.table else { return }
                let selection = self.parent.session.selection
                self.updating = true
                table.reloadData()
                if let selection,
                    let row = self.rows.firstIndex(where: { $0.matches.contains { $0.id == selection } })
                {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                else {
                    table.deselectAll(nil)
                }
                self.updating = false
                self.scrolled()
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.session.selection =
                rows.indices.contains(table.selectedRow) ? activeResult(in: rows[table.selectedRow]).id : nil
        }
        @objc func clicked() {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let result = activeResult(in: rows[table.clickedRow])
            clearResultSelection()
            parent.open(result)
        }
        @objc func activate() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            let result = activeResult(in: rows[table.selectedRow])
            clearResultSelection()
            parent.open(result)
        }
        private func clearResultSelection() {
            parent.session.selection = nil
            guard let table else { return }
            table.deselectAll(nil)
            if let focusedView = table.window?.firstResponder as? NSView,
                focusedView === table || focusedView.isDescendant(of: table)
            {
                table.window?.makeFirstResponder(nil)
            }
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("search-result")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultCell ?? SearchResultCell()
            cell.identifier = identifier
            configure(cell, row: row, width: tableColumn?.width ?? tableView.bounds.width)
            let groupID = rows[row].id
            cell.play = { [weak self] in
                guard let self, let group = self.rows.first(where: { $0.id == groupID }) else { return }
                let result = self.activeResult(in: group)
                self.clearResultSelection()
                self.parent.play(result)
            }
            cell.selectMatch = { [weak self] matchID in
                self?.selectMatch(matchID, in: groupID)
            }
            cell.navigate = { [weak self] in
                guard let self, let group = self.rows.first(where: { $0.id == groupID }) else { return }
                let result = self.activeResult(in: group)
                self.clearResultSelection()
                self.parent.navigate(result)
            }
            return cell
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let width = tableView.tableColumns[0].width
            configure(measurementCell, row: row, width: width)
            return measurementCell.height(fitting: width)
        }
        private func configure(_ cell: SearchResultCell, row: Int, width: CGFloat) {
            cell.updateLayout(width: width)
            let group = rows[row]
            let result = activeResult(in: group)
            cell.configure(
                group, selected: result, summary: parent.summaries[result.meetingID],
                timelines: parent.timelines,
                showScore: parent.showRankingDetails,
                canPlay: parent.canPlay && parent.playableMeetings.contains(result.meetingID))
        }

        private func activeResult(in group: SearchResultGroup) -> SearchDisplayResult {
            group.matches.first(where: { $0.id == parent.session.activeMatches[group.id] }) ?? group.matches[0]
        }

        private func selectMatch(_ matchID: String, in groupID: UUID) {
            guard let row = rows.firstIndex(where: { $0.id == groupID }),
                let result = rows[row].matches.first(where: { $0.id == matchID })
            else { return }
            parent.session.activeMatches[groupID] = matchID
            renderedMatches = parent.session.activeMatches
            parent.session.selection = nil
            if let table {
                updating = true
                table.deselectAll(nil)
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SearchResultCell {
                    configure(cell, row: row, width: table.tableColumns[0].width)
                }
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                updating = false
            }
            parent.selectMatch(result)
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
    let title = NSTextField(wrappingLabelWithString: "")
    let metadata = NSTextField(wrappingLabelWithString: "")
    let source = NSTextField(labelWithString: "")
    private let sourceBadge = NSView()
    private let columns = NSStackView()
    private var wideConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    private var usesWideLayout = false
    let summary = NSTextField(labelWithString: "")
    let excerpt = NSTextField(wrappingLabelWithString: "")
    let score = NSTextField(labelWithString: "")
    let rank = NSTextField(labelWithString: "")
    let timeline = SearchTimelineView()
    let playButton = NSButton(title: "", target: nil, action: nil)
    let navigateButton = NSButton(title: "", target: nil, action: nil)
    var play: (() -> Void)?
    var navigate: (() -> Void)?
    var selectMatch: ((String) -> Void)?
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            timeline.emphasized = backgroundStyle == .emphasized
            source.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for field in [metadata, summary, score, rank] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        sourceBadge.wantsLayer = true
        sourceBadge.layer?.cornerRadius = 4
        source.alignment = .center
        rank.alignment = .center
        excerpt.font = .systemFont(ofSize: NSFont.systemFontSize)
        for field in [title, metadata, source, summary, excerpt, score, rank] {
            field.lineBreakMode = [title, metadata, excerpt].contains(field) ? .byWordWrapping : .byTruncatingTail
            field.maximumNumberOfLines = field === excerpt ? 4 : (field === title || field === metadata ? 2 : 1)
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        sourceBadge.translatesAutoresizingMaskIntoConstraints = false
        sourceBadge.addSubview(source)
        NSLayoutConstraint.activate([
            source.leadingAnchor.constraint(equalTo: sourceBadge.leadingAnchor, constant: 8),
            source.trailingAnchor.constraint(equalTo: sourceBadge.trailingAnchor, constant: -8),
            source.topAnchor.constraint(equalTo: sourceBadge.topAnchor, constant: 4),
            source.bottomAnchor.constraint(equalTo: sourceBadge.bottomAnchor, constant: -4),
        ])
        source.setContentHuggingPriority(.required, for: .horizontal)
        source.setContentCompressionResistancePriority(.required, for: .horizontal)

        let meetingColumn = NSStackView(views: [title, summary, sourceBadge, metadata])
        meetingColumn.orientation = .vertical
        meetingColumn.alignment = .leading
        meetingColumn.spacing = 6
        meetingColumn.setCustomSpacing(4, after: title)
        for field in [title, summary, metadata] {
            field.widthAnchor.constraint(equalTo: meetingColumn.widthAnchor).isActive = true
        }

        let passageColumn = NSStackView(views: [timeline, excerpt])
        passageColumn.orientation = .vertical
        passageColumn.alignment = .leading
        passageColumn.spacing = 6
        timeline.heightAnchor.constraint(equalToConstant: 28).isActive = true
        timeline.widthAnchor.constraint(equalTo: passageColumn.widthAnchor).isActive = true
        excerpt.widthAnchor.constraint(equalTo: passageColumn.widthAnchor).isActive = true
        timeline.selectMatch = { [weak self] in self?.selectMatch?($0) }

        columns.addArrangedSubview(meetingColumn)
        columns.addArrangedSubview(passageColumn)
        columns.orientation = .vertical
        columns.alignment = .leading
        columns.spacing = 12
        wideConstraints = [
            meetingColumn.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.32),
            passageColumn.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
        ]
        compactConstraints = [
            meetingColumn.widthAnchor.constraint(equalTo: columns.widthAnchor),
            passageColumn.widthAnchor.constraint(equalTo: columns.widthAnchor),
        ]
        NSLayoutConstraint.activate(compactConstraints)

        let content = NSStackView(views: [columns, score])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        for view in [columns, score] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for field in [title, summary, metadata, excerpt, score, rank] {
            field.setContentHuggingPriority(.required, for: .vertical)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        addSubview(rank)
        playButton.bezelStyle = .circular
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.target = self
        addSubview(playButton)
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageOnly
        playButton.action = #selector(playResult)
        navigateButton.isBordered = false
        navigateButton.contentTintColor = .secondaryLabelColor
        navigateButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        navigateButton.translatesAutoresizingMaskIntoConstraints = false
        navigateButton.target = self
        navigateButton.action = #selector(navigateToResult)
        navigateButton.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)
        navigateButton.imagePosition = .imageOnly
        addSubview(navigateButton)
        NSLayoutConstraint.activate([
            rank.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rank.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rank.widthAnchor.constraint(equalToConstant: 36),
            playButton.centerXAnchor.constraint(equalTo: rank.centerXAnchor),
            playButton.topAnchor.constraint(equalTo: rank.bottomAnchor, constant: 8),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            navigateButton.centerXAnchor.constraint(equalTo: rank.centerXAnchor),
            navigateButton.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 4),
            navigateButton.widthAnchor.constraint(equalToConstant: 28),
            navigateButton.heightAnchor.constraint(equalToConstant: 28),
            navigateButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        score.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
    }
    func height(fitting width: CGFloat) -> CGFloat {
        let constraint = widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        defer { constraint.isActive = false }
        layoutSubtreeIfNeeded()
        return ceil(fittingSize.height)
    }
    func updateLayout(width: CGFloat) {
        // Leaves about 324 points for a passage: roughly ten English words at the system font size.
        let wide = width >= 580
        if wide != usesWideLayout {
            usesWideLayout = wide
            NSLayoutConstraint.deactivate(wide ? compactConstraints : wideConstraints)
            columns.orientation = wide ? .horizontal : .vertical
            columns.alignment = wide ? .top : .leading
            columns.spacing = wide ? 24 : 12
            NSLayoutConstraint.activate(wide ? wideConstraints : compactConstraints)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func playResult() { play?() }
    @objc private func navigateToResult() { navigate?() }
    func configure(
        _ group: SearchResultGroup, selected result: SearchDisplayResult, summary summaryTitle: String?,
        timelines: [String: SearchResultTimeline], showScore: Bool, canPlay: Bool
    ) {
        rank.stringValue = group.rank.formatted()
        rank.setAccessibilityLabel("First match rank \(group.rank)")
        title.stringValue = result.title
        title.toolTip = result.title
        metadata.stringValue = result.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        source.stringValue = result.sourceLabel
        let tint: NSColor = result.passage?.kind == .title ? .systemPurple : .systemBlue
        source.textColor = tint
        sourceBadge.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        summary.stringValue = summaryTitle ?? ""
        summary.toolTip = summaryTitle
        summary.isHidden = summary.stringValue.isEmpty
        score.stringValue = showScore ? result.scoreBreakdown?.description ?? "" : ""
        score.toolTip = score.stringValue
        score.isHidden = !showScore || result.scoreBreakdown == nil
        excerpt.stringValue =
            result.passage?.kind == .title
            ? ""
            : result.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        excerpt.isHidden = excerpt.stringValue.isEmpty
        timeline.isHidden = !group.matches.contains { timelines[$0.id] != nil || $0.playbackStart != nil }
        timeline.configure(matches: group.matches, selected: result, timelines: timelines)
        // A reused cell can need fresh backing contents even when its interval is unchanged.
        timeline.needsDisplay = true
        let start = result.playbackStart
        playButton.isHidden = start == nil
        playButton.isEnabled = canPlay && start != nil
        playButton.toolTip =
            canPlay
            ? start.map { "Open meeting and play from " + playbackTime($0) }
            : "Playback is unavailable while recording or when this meeting has no audio."
        playButton.setAccessibilityLabel("Open \(result.title) and play from \(playbackTime(start ?? 0))")
        navigateButton.toolTip = "Show in Meetings"
        navigateButton.setAccessibilityLabel("Show \(result.title) in Meetings")
        toolTip = result.passage?.kind == .title ? result.title : result.excerpt
    }
}

private extension SearchDisplayResult {
    var sourceLabel: String {
        switch passage?.kind {
        case .title: "Meeting"
        case .notes: "Notes"
        case .summary: "Summary"
        case .transcript: "Transcript"
        case nil: "Audio"
        }
    }
}

/// Source intervals and native match controls remain independent of playback progress.
class SearchTimelineView: NSView {
    private var range: SearchResultTimeline?
    private var start: Double?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var first = "" as NSString
    private var last = "" as NSString
    private var firstWidth: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var segments: [(range: SearchResultTimeline, button: SearchSegmentButton)] = []
    var selectMatch: ((String) -> Void)?
    var emphasized = false { didSet { if oldValue != emphasized { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    func configure(
        matches: [SearchDisplayResult], selected: SearchDisplayResult, timelines: [String: SearchResultTimeline]
    ) {
        let focusedMatch = segments.first(where: { window?.firstResponder === $0.button })?.button.matchID
        configure(timelines[selected.id], start: selected.playbackStart)
        for segment in segments { segment.button.removeFromSuperview() }
        segments.removeAll(keepingCapacity: true)
        // Longer intervals stay behind short ones; a meeting-title match must not block passage controls.
        let ordered = matches.enumerated().sorted { lhs, rhs in
            let left = timelines[lhs.element.id].map { $0.end - $0.start } ?? 0
            let right = timelines[rhs.element.id].map { $0.end - $0.start } ?? 0
            if left != right { return left > right }
            if lhs.element.id == selected.id { return false }
            if rhs.element.id == selected.id { return true }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for match in ordered {
            guard let interval = timelines[match.id] else { continue }
            let button = SearchSegmentButton(frame: .zero)
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.title = ""
            button.state = match.id == selected.id ? .on : .off
            button.matchID = match.id
            button.isMeeting = match.passage?.kind == .title
            button.focusRingType = .exterior
            let label = "\(match.sourceLabel) from \(playbackTime(interval.start)) to \(playbackTime(interval.end))"
            button.setAccessibilityLabel(label)
            button.toolTip = label + "\n" + match.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            button.onSelect = { [weak self] in self?.selectMatch?(match.id) }
            addSubview(button)
            segments.append((interval, button))
        }
        if let focusedMatch, let button = segments.first(where: { $0.button.matchID == focusedMatch })?.button {
            window?.makeFirstResponder(button)
        }
        setAccessibilityElement(segments.isEmpty)
        needsLayout = true
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        for segment in segments {
            let marker = markerFrame(for: segment.range, y: 17, height: 11)
            segment.button.frame = marker
            segment.button.markerRect = NSRect(
                x: 0, y: segment.button.isMeeting ? 9 : 3,
                width: marker.width, height: segment.button.isMeeting ? 2 : 6)
        }
    }
    private func markerFrame(for range: SearchResultTimeline, y: CGFloat, height: CGFloat) -> NSRect {
        let trackWidth = max(0, bounds.width)
        let width = min(trackWidth, max(12, trackWidth * (range.endFraction - range.startFraction)))
        // Keep the start accurate until the enlarged marker reaches the recording's right edge.
        let x = min(trackWidth * range.startFraction, trackWidth - width)
        return NSRect(x: x, y: y, width: width, height: height)
    }
    func configure(_ range: SearchResultTimeline?, start: Double?) {
        guard self.range != range || self.start != start else { return }
        self.range = range
        self.start = start
        first = (range.map { playbackTime($0.start) } ?? start.map(playbackTime) ?? "") as NSString
        last = (range.map { playbackTime($0.end) } ?? "") as NSString
        let metrics: [NSAttributedString.Key: Any] = [.font: labelFont]
        firstWidth = first.size(withAttributes: metrics).width
        lastWidth = last.size(withAttributes: metrics).width
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            range.map {
                "Match from \(playbackTime($0.start)) to \(playbackTime($0.end)), recording length \(playbackTime($0.duration))"
            } ?? start.map { "Starts at \(playbackTime($0))" } ?? "Timing unavailable")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
        ]
        guard let range else {
            first.draw(at: .zero, withAttributes: attributes)
            if !segments.isEmpty {
                NSColor.separatorColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 24, width: bounds.width, height: 2), xRadius: 1, yRadius: 1)
                    .fill()
            }
            return
        }
        let width = bounds.width
        let left = width * range.startFraction
        let right = width * range.endFraction
        (emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.35) : .separatorColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 24, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        if segments.isEmpty {
            (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).setFill()
            NSBezierPath(rect: markerFrame(for: range, y: 23, height: 4)).fill()
        }
        var firstX = min(max(0, left - firstWidth / 2), max(0, width - firstWidth))
        var lastX = min(max(0, right - lastWidth / 2), max(0, width - lastWidth))
        if lastX < firstX + firstWidth + 8 {
            let center = (left + right) / 2
            firstX = max(0, min(center - firstWidth - 4, width - firstWidth - lastWidth - 8))
            lastX = firstX + firstWidth + 8
        }
        first.draw(at: NSPoint(x: firstX, y: 0), withAttributes: attributes)
        last.draw(at: NSPoint(x: lastX, y: 0), withAttributes: attributes)
    }
}

private final class SearchSegmentButton: NSButton {
    var onSelect: (() -> Void)?
    var matchID = ""
    var isMeeting = false
    override var isFlipped: Bool { true }
    var markerRect = NSRect.zero { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(selectSegment)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectSegment() { onSelect?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(rect: bounds).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(state == .on ? 1 : 0.5).setFill()
        let marker = NSBezierPath(rect: markerRect)
        marker.fill()
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            marker.lineWidth = 1
            marker.stroke()
        }
    }
}
