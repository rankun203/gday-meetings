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
    @ViewState private var timelines: [String: SearchResultTimeline] = [:]
    @ViewState private var preview: SearchDisplayResult?

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
                .frame(maxWidth: 750)
                .frame(maxWidth: .infinity)
            NativeSearchResults(
                session: session, results: session.displayResults, generation: session.generation,
                showRankingDetails: showRankingDetails, summaries: summaries, playableMeetings: playableMeetings,
                canPlay: canPlay, timelines: timelines,
                open: open, play: play, preview: { preview = $0 }
            )
            .frame(maxWidth: 750)
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
        .sheet(item: $preview) { result in
            SearchResultPreview(
                result: result, summary: summaries[result.meetingID], timeline: timelines[result.id],
                canPlay: canPlay && playableMeetings.contains(result.meetingID), play: { play(result) })
        }
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
    let open: (SearchDisplayResult) -> Void
    let play: (SearchDisplayResult) -> Void
    let preview: (SearchDisplayResult) -> Void

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
        table.action = #selector(Coordinator.clicked)
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
        coordinator.pendingPreview?.cancel()
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
        var pendingPreview: DispatchWorkItem?
        init(_ parent: NativeSearchResults) { self.parent = parent }
        func update(_ value: NativeSearchResults) {
            guard let table, let scroll else { return }
            updating = true
            let presentationChanged =
                parent.showRankingDetails != value.showRankingDetails || parent.summaries != value.summaries
                || parent.canPlay != value.canPlay || parent.playableMeetings != value.playableMeetings
                || parent.timelines != value.timelines
            parent = value
            let reset = generation != value.generation
            if reset {
                announced = false
                pendingPreview?.cancel()
            }
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
            parent.showRankingDetails && rows[row].scoreBreakdown != nil ? 216 : 190
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.session.selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        }
        @objc func clicked() {
            pendingPreview?.cancel()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let result = rows[table.clickedRow]
            let work = DispatchWorkItem { [weak self] in self?.parent.preview(result) }
            pendingPreview = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
        @objc func activate() {
            pendingPreview?.cancel()
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            parent.open(rows[table.selectedRow])
        }
        @objc func doubleClicked() {
            pendingPreview?.cancel()
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
                result, rank: row + 1, summary: parent.summaries[result.meetingID],
                timeline: parent.timelines[result.id],
                showScore: parent.showRankingDetails,
                canPlay: parent.canPlay && parent.playableMeetings.contains(result.meetingID))
            cell.play = { [weak self] in
                self?.pendingPreview?.cancel()
                self?.parent.play(result)
            }
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
    let title = NSTextField(wrappingLabelWithString: "")
    let metadata = NSTextField(wrappingLabelWithString: "")
    let source = NSTextField(labelWithString: "")
    let summary = NSTextField(labelWithString: "")
    let excerpt = NSTextField(wrappingLabelWithString: "")
    let score = NSTextField(labelWithString: "")
    let rank = NSTextField(labelWithString: "")
    let timeline = SearchTimelineView()
    let playButton = NSButton(title: "", target: nil, action: nil)
    var play: (() -> Void)?
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
        source.wantsLayer = true
        source.layer?.cornerRadius = 4
        source.alignment = .center
        rank.alignment = .center
        excerpt.font = .systemFont(ofSize: NSFont.systemFontSize)
        for field in [title, metadata, source, summary, excerpt, score, rank] {
            field.lineBreakMode = [title, metadata, excerpt].contains(field) ? .byWordWrapping : .byTruncatingTail
            field.maximumNumberOfLines = field === excerpt ? 4 : (field === title || field === metadata ? 2 : 1)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        timeline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeline)
        playButton.bezelStyle = .circular
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.target = self
        addSubview(playButton)
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageOnly
        playButton.action = #selector(playResult)
        NSLayoutConstraint.activate([
            rank.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rank.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rank.widthAnchor.constraint(equalToConstant: 36),
            playButton.centerXAnchor.constraint(equalTo: rank.centerXAnchor),
            playButton.topAnchor.constraint(equalTo: rank.bottomAnchor, constant: 8),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.heightAnchor.constraint(lessThanOrEqualToConstant: 34),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            summary.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            source.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            source.topAnchor.constraint(equalTo: topAnchor, constant: 76),
            source.widthAnchor.constraint(equalToConstant: 90),
            source.heightAnchor.constraint(equalToConstant: 22),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metadata.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 8),
            metadata.widthAnchor.constraint(equalToConstant: 150),
            timeline.leadingAnchor.constraint(equalTo: metadata.trailingAnchor, constant: 18),
            timeline.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            timeline.topAnchor.constraint(equalTo: source.topAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 28),
            excerpt.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
            excerpt.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 8),
            excerpt.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            excerpt.heightAnchor.constraint(lessThanOrEqualToConstant: 68),
            score.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            score.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            score.topAnchor.constraint(equalTo: topAnchor, constant: 188),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        score.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func playResult() { play?() }
    func configure(
        _ result: SearchDisplayResult, rank position: Int, summary summaryTitle: String?,
        timeline range: SearchResultTimeline?, showScore: Bool, canPlay: Bool
    ) {
        rank.stringValue = position.formatted()
        rank.setAccessibilityLabel("Result \(position)")
        title.stringValue = result.title
        title.toolTip = result.title
        metadata.stringValue = result.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        source.stringValue = result.sourceLabel
        let tint: NSColor = result.passage?.kind == .title ? .systemPurple : .systemBlue
        source.textColor = tint
        source.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        summary.stringValue = summaryTitle ?? ""
        summary.toolTip = summaryTitle
        score.stringValue = showScore ? result.scoreBreakdown?.description ?? "" : ""
        score.toolTip = score.stringValue
        score.isHidden = !showScore || result.scoreBreakdown == nil
        excerpt.stringValue =
            result.passage?.kind == .title ? "" : result.excerpt.replacingOccurrences(of: "\n", with: " ")
        timeline.configure(range, start: result.playbackStart)
        let start = result.playbackStart
        playButton.isHidden = start == nil
        playButton.isEnabled = canPlay && start != nil
        playButton.toolTip =
            canPlay
            ? start.map { "Play from " + playbackTime($0) }
            : "Playback is unavailable while recording or when this meeting has no audio."
        playButton.setAccessibilityLabel("Play \(result.title) from \(playbackTime(start ?? 0))")
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

/// Draws source time only; intentionally has no tracking or playback state.
class SearchTimelineView: NSView {
    private var range: SearchResultTimeline?
    private var start: Double?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var first = "" as NSString
    private var last = "" as NSString
    private var firstWidth: CGFloat = 0
    private var lastWidth: CGFloat = 0
    var emphasized = false { didSet { if oldValue != emphasized { needsDisplay = true } } }
    override var isFlipped: Bool { true }
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
            return
        }
        let width = bounds.width
        let left = width * range.startFraction
        let right = width * range.endFraction
        (emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.35) : .separatorColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 24, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: left, y: 23, width: max(2, right - left), height: 4), xRadius: 1, yRadius: 1
        ).fill()
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

private struct SearchResultPreview: View {
    let result: SearchDisplayResult
    let summary: String?
    let timeline: SearchResultTimeline?
    let canPlay: Bool
    let play: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.title).font(.title2).textSelection(.enabled)
            if let summary, !summary.isEmpty { Text(summary).foregroundStyle(.secondary) }
            HStack {
                Text(result.sourceLabel)
                if let date = result.createdAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
            }.font(.callout).foregroundStyle(.secondary)
            if let timeline {
                Text("\(playbackTime(timeline.start))–\(playbackTime(timeline.end))").monospacedDigit()
            }
            if result.passage?.kind != .title {
                ScrollView {
                    Text(result.excerpt).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
            HStack {
                if result.playbackStart != nil {
                    Button("Play", systemImage: "play.fill", action: play).disabled(!canPlay)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 600).frame(minHeight: 240, maxHeight: 480)
    }
}
