import AppKit
import Combine
import SwiftUI

struct TranscriptDisplayRow: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let end: Double
    let speaker: String
    let speakerID: UUID?
    let text: String
    var personID: UUID? = nil
    var speakerColorIndex: Int? = nil
    var speakerColorKey: String? = nil
    var isProvisional = false
    var provisionalTextRanges: [NSRange]? = nil
    var recentWordRanges: [NSRange] = []
    var accessibilityHelp: String? = nil
    var isSourcePlaceholder = false
    let textRevision: UInt64
    init(
        id: UUID, start: Double, end: Double, speaker: String, speakerID: UUID?, text: String,
        personID: UUID? = nil, speakerColorIndex: Int? = nil, speakerColorKey: String? = nil,
        isProvisional: Bool = false, provisionalTextRanges: [NSRange]? = nil,
        recentWordRanges: [NSRange] = [], accessibilityHelp: String? = nil, isSourcePlaceholder: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.speakerID = speakerID
        self.text = text
        self.personID = personID
        self.speakerColorIndex = speakerColorIndex
        self.speakerColorKey = speakerColorKey
        self.isProvisional = isProvisional
        self.provisionalTextRanges = provisionalTextRanges
        self.recentWordRanges = recentWordRanges
        self.accessibilityHelp = accessibilityHelp
        self.isSourcePlaceholder = isSourcePlaceholder
        // Compute once when a row is constructed, never during a height lookup.
        self.textRevision = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
    var canAssignPerson: Bool { speakerID != nil && !isSourcePlaceholder }
}

/// One selected transcript, reusable native rows, and the window's shared field
/// editor. Scrolling performs no store lookups, file reads, or SwiftUI row builds.
struct NativeTranscriptView: NSViewRepresentable {
    var rows: [TranscriptDisplayRow]
    var layoutService: TranscriptLayoutService? = nil
    var generation: Int
    var showsSpeakers: Bool
    var editable: Bool
    var canPlay: Bool
    var playback: MeetingPlayback? = nil
    var meetingID: UUID? = nil
    var transcriptSourceID: UUID? = nil
    var sourceRowIDs: Set<UUID>? = nil
    /// A review link positions the transcript without selecting or starting audio.
    var initialRowID: UUID? = nil
    var liveRows: LiveTranscriptStreamDisplayCache? = nil
    var captureSave: ((UUID) -> (String) -> Void)? = nil
    /// nil retains saved-transcript playback following.
    var followsLive: Bool? = nil
    var pauseLiveFollowing: (() -> Void)? = nil
    var play: (Double) -> Void
    var save: (UUID, String) -> Void
    var speakerPicker: (UUID, @escaping () -> Void) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TranscriptNativeScrollView()
        scroll.viewportChanged = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = TranscriptNativeTable()
        scroll.willScroll = { [weak table, weak coordinator = context.coordinator] in
            table?.delayHover()
            coordinator?.userScrolled()
        }
        let scroller = TranscriptNativeScroller()
        scroller.trackingChanged = { [weak coordinator = context.coordinator] in
            coordinator?.scrollerTrackingChanged($0)
        }
        scroller.userScrolled = { [weak coordinator = context.coordinator] in coordinator?.userScrolled() }
        scroll.verticalScroller = scroller
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.usesAutomaticRowHeights = false
        table.setAccessibilityLabel("Transcript")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        context.coordinator.table = table
        table.widthChanged = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        table.editSelected = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.edit(row: coordinator.table?.selectedRow ?? -1)
        }
        table.userInteracted = { [weak coordinator = context.coordinator] in coordinator?.userSelected() }
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
        NSPopoverDelegate
    {
        var parent: NativeTranscriptView
        weak var table: TranscriptNativeTable?
        var generation: Int?
        var rows: [TranscriptDisplayRow] = []
        let heights: TranscriptLayoutService
        private let pageID = UUID()
        private let fallbackMeetingID = UUID()
        private var knownSourceRowIDs: Set<UUID> = []
        private var measurementKeys: [TranscriptMeasurementKey] = []
        private var rowIndices: [UUID: Int] = [:]
        private var navigationAnchorID: UUID?
        private var scrollerTracking = false
        private var duplicateAppliedHeights: [Int: CGFloat] = [:]
        private var duplicateRowIndices: [UUID: [Int]] = [:]
        private var appliedHeights: [UUID: CGFloat] = [:]
        private var clipObserver: NSObjectProtocol?
        private var measurementWork: DispatchWorkItem?
        var pendingClick: DispatchWorkItem?
        var popover: NSPopover?
        private var playbackSubscription: AnyCancellable?
        private var lastSeekRevision: UInt64?
        private var needsInitialPosition = true
        private var speakerColors: [String: Int] = [:]
        private var layoutWork: DispatchWorkItem?
        private var settledWidth: CGFloat?
        private var settledScale: CGFloat?
        private var followTimer: Timer?
        var isFollowing: Bool { followTimer != nil }
        var hasNavigationAnchor: Bool { navigationAnchorID != nil }
        private var followStarted: TimeInterval = 0
        private var followStart: CGFloat = 0
        private var followTarget: CGFloat = 0
        private var userScrollUntil: TimeInterval = 0
        private weak var observedPlayback: MeetingPlayback?
        private var playbackOrder: [(start: Double, end: Double, row: Int)] = []
        private var playbackMaxEnds: [Double] = []
        private(set) var activeRows: Set<Int> = []
        private(set) var activeRow: Int?
        private var editedID: UUID?
        private weak var editedCell: TranscriptNativeCell?
        private let editSession = TranscriptEditSession()
        private var deferredLiveUpdate: NativeTranscriptView?
        private var liveFollowPaused = false
        private var liveFrozenCount = 0
        private var liveResetRevision: Int?

        init(_ parent: NativeTranscriptView) {
            self.parent = parent
            self.heights = parent.layoutService ?? TranscriptLayoutService()
            super.init()
        }
        func update(_ value: NativeTranscriptView) {
            if parent.meetingID != value.meetingID { speakerColors = [:] }
            let sourceChanged =
                parent.meetingID != value.meetingID
                || parent.transcriptSourceID != value.transcriptSourceID || generation == nil
            let presentationChanged =
                parent.showsSpeakers != value.showsSpeakers
                || parent.editable != value.editable || parent.canPlay != value.canPlay
            let changed =
                sourceChanged || presentationChanged
                || (value.liveRows != nil ? generation != value.generation : rows != value.rows)
            let followChanged = parent.followsLive != value.followsLive
            let navigationChanged = parent.initialRowID != value.initialRowID
            if navigationChanged {
                needsInitialPosition = true
                userScrollUntil = 0
            }
            if followChanged, value.followsLive == true { liveFollowPaused = false }
            if !sourceChanged, value.followsLive != nil, editedID != nil || popover?.isShown == true {
                deferredLiveUpdate = value
                return
            }
            parent = value
            if navigationChanged {
                table?.enumerateAvailableRowViews { view, index in
                    (view as? TranscriptNativeRowView)?.isReviewTarget =
                        self.rows.indices.contains(index) && self.rows[index].id == value.initialRowID
                }
            }
            deferredLiveUpdate = nil
            guard changed, let table else {
                observePlayback()
                refreshPlayback()
                if followChanged || navigationChanged { scheduleLayout() }
                return
            }
            cancelFollow()
            if sourceChanged {
                deferredLiveUpdate = nil
                liveFollowPaused = false
                needsInitialPosition = true
                navigationAnchorID = nil
                duplicateAppliedHeights = [:]
                userScrollUntil = 0
                popover?.close()
            }
            pendingClick?.cancel()
            let selectedIndex = table.selectedRow
            let selection = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
            finishEdit()
            // Unchanged cells survive a partial reload. Clear the previous
            // highlight while its index still refers to the old row set.
            updatePlayback(meetingID: nil, time: 0, follows: false)
            let update: TranscriptRowUpdate
            var selectionBoundary = 0
            var removedLiveIDs: Set<UUID> = []
            let liveReset = value.liveRows.map { liveResetRevision != $0.resetRevision } ?? false
            if let live = value.liveRows {
                let boundary = sourceChanged || presentationChanged || liveReset ? 0 : min(liveFrozenCount, rows.count)
                selectionBoundary = boundary
                let previousTail = Array(rows[boundary...])
                let nextTail = live.rows(from: boundary)
                removedLiveIDs = Set(previousTail.map(\.id)).subtracting(nextTail.map(\.id))
                if boundary > 0 {
                    for row in previousTail {
                        if let index = rowIndices[row.id], index >= boundary { rowIndices.removeValue(forKey: row.id) }
                        if let duplicates = duplicateRowIndices[row.id] {
                            let retained = duplicates.filter { $0 < boundary }
                            if retained.isEmpty {
                                duplicateRowIndices.removeValue(forKey: row.id)
                            }
                            else {
                                duplicateRowIndices[row.id] = retained
                            }
                        }
                    }
                }
                registerSpeakerColors(nextTail)
                update = TranscriptRowUpdate(previous: previousTail, current: nextTail, offset: boundary)
                rows.replaceSubrange(boundary..., with: nextTail)
                liveFrozenCount = live.frozenCount
                liveResetRevision = live.resetRevision
                playbackOrder.removeAll(keepingCapacity: true)
                playbackMaxEnds.removeAll(keepingCapacity: true)
            }
            else {
                registerSpeakerColors(value.rows)
                update = TranscriptRowUpdate(previous: rows, current: value.rows)
                rows = value.rows
                playbackOrder = rows.enumerated().filter {
                    $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end > $0.element.start
                }.map {
                    ($0.element.start, $0.element.end, $0.offset)
                }
                .sorted { $0.start == $1.start ? $0.row < $1.row : $0.start < $1.start }
                var maximumEnd = -Double.infinity
                playbackMaxEnds = playbackOrder.map { interval in
                    maximumEnd = max(maximumEnd, interval.end)
                    return maximumEnd
                }

            }
            if value.liveRows == nil {
                let authoritativeIDs = value.sourceRowIDs ?? Set(rows.map(\.id))
                if !sourceChanged { removedLiveIDs.formUnion(knownSourceRowIDs.subtracting(authoritativeIDs)) }
                knownSourceRowIDs = authoritativeIDs
            }
            for id in removedLiveIDs { appliedHeights.removeValue(forKey: id) }
            let scale = table.window?.backingScaleFactor ?? 1
            let width = TranscriptTextMeasurement.normalizedTextWidth(
                table.tableColumns.first?.width ?? table.bounds.width, showsSpeakers: parent.showsSpeakers, scale: scale
            )
            let widthChanged = settledWidth != width || settledScale != scale
            rebuildMeasurementKeys(from: value.liveRows != nil && !widthChanged ? selectionBoundary : 0)
            if !removedLiveIDs.isEmpty {
                heights.invalidate(meetingID: parent.meetingID ?? fallbackMeetingID, removing: removedLiveIDs)
            }
            if sourceChanged || heights.isAvailable(to: pageID) { activateMeasurements() }
            generation = value.generation
            activeRow = nil
            activeRows.removeAll(keepingCapacity: true)
            withoutLayoutAnimation {
                // The initial reload uses current keys. Partial updates also need
                // every row's geometry invalidated when the column changed first.
                settledWidth = width
                settledScale = scale
                if sourceChanged || presentationChanged || liveReset {
                    table.reloadData()
                }
                else {
                    table.beginUpdates()
                    if !update.removed.isEmpty { table.removeRows(at: update.removed, withAnimation: []) }
                    if !update.inserted.isEmpty { table.insertRows(at: update.inserted, withAnimation: []) }
                    table.endUpdates()
                    if widthChanged {
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
                    }
                    if !update.changed.isEmpty {
                        table.reloadData(
                            forRowIndexes: update.changed,
                            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                        table.noteHeightOfRows(withIndexesChanged: update.changed)
                    }
                }
            }
            observePlayback()
            refreshPlayback()
            scheduleLayout()
            scheduleMeasurements()
            if let selection {
                let index =
                    rows.indices.contains(selectedIndex) && rows[selectedIndex].id == selection
                    ? selectedIndex : rows[selectionBoundary...].firstIndex(where: { $0.id == selection })
                if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            }
        }
        private func observePlayback() {
            guard observedPlayback !== parent.playback else { return }
            playbackSubscription = nil
            lastSeekRevision = nil
            observedPlayback = parent.playback
            guard let playback = parent.playback else { return }
            playbackSubscription = playback.progress.$snapshot.sink { [weak self] snapshot in
                guard let self else { return }
                let sought = self.lastSeekRevision.map { $0 != snapshot.seekRevision } ?? false
                self.lastSeekRevision = snapshot.seekRevision
                if snapshot.scrubTime != nil { self.cancelFollow() }
                self.updatePlayback(
                    meetingID: snapshot.meetingID, time: snapshot.displayedTime,
                    follows: snapshot.scrubTime == nil && !sought)
                if sought && !self.needsInitialPosition { self.followActiveRow(force: true) }
            }
        }
        private func refreshPlayback() {
            let snapshot = parent.playback?.progress.snapshot
            updatePlayback(meetingID: snapshot?.meetingID, time: snapshot?.displayedTime ?? 0, follows: false)
        }
        func updatePlayback(meetingID: UUID?, time: Double, follows: Bool = true) {
            var next: Int?
            var nextRows: Set<Int> = []
            if let meetingID, meetingID == parent.meetingID, time.isFinite {
                var low = 0
                var high = playbackOrder.count
                while low < high {
                    let middle = (low + high) / 2
                    if playbackOrder[middle].start <= time {
                        low = middle + 1
                    }
                    else {
                        high = middle
                    }
                }
                // Earlier intervals can outlast later starts, even within the same
                // source. Stop only when every preceding interval has ended.
                while low > 0 && playbackMaxEnds[low - 1] > time {
                    low -= 1
                    let interval = playbackOrder[low]
                    if time < interval.end {
                        nextRows.insert(interval.row)
                        if next == nil { next = interval.row }
                    }
                }
            }
            guard nextRows != activeRows else { return }
            let changedRows = activeRows.symmetricDifference(nextRows)
            activeRows = nextRows
            activeRow = next
            if next == nil { cancelFollow() }
            for row in changedRows {
                if let view = table?.rowView(atRow: row, makeIfNecessary: false) as? TranscriptNativeRowView {
                    view.isPlaybackRow = nextRows.contains(row)
                }
                (table?.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptNativeCell)?.isPlaybackRow =
                    nextRows.contains(row)
            }
            if follows { followActiveRow(force: false) }
        }
        func tearDown() {
            deferredLiveUpdate = nil
            finishEdit()
            pendingClick?.cancel()
            popover?.close()
            cancelFollow()
            layoutWork?.cancel()
            layoutWork = nil
            playbackSubscription = nil
            measurementWork?.cancel()
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clipObserver = nil
            heights.deactivate(pageID)
        }
        func userScrolled() {
            navigationAnchorID = nil
            pauseLiveFollow()
            userScrollUntil = ProcessInfo.processInfo.systemUptime + 4
            cancelFollow()
        }
        func scrollerTrackingChanged(_ tracking: Bool) {
            scrollerTracking = tracking
            if !tracking { scheduleMeasurements() }
        }
        func userSelected() {
            navigationAnchorID = nil
            guard parent.followsLive != nil else { return }
            pauseLiveFollow()
            cancelFollow()
        }
        private func pauseLiveFollow() {
            guard parent.followsLive != nil else { return }
            liveFollowPaused = true
            parent.pauseLiveFollowing?()
        }
        func cancelFollow() {
            followTimer?.invalidate()
            followTimer = nil
        }
        private func followActiveRow(force: Bool, animated: Bool = true) {
            guard parent.followsLive == nil else { return }
            guard !needsInitialPosition else { return }
            guard editedID == nil, popover?.isShown != true,
                force || ProcessInfo.processInfo.systemUptime >= userScrollUntil,
                let row = activeRow, let table, row < table.numberOfRows,
                let scroll = table.enclosingScrollView
            else { return }
            let clip = scroll.contentView
            let rowTop = table.rect(ofRow: row).minY
            let target = min(
                max(0, rowTop - clip.bounds.height * 0.3), max(0, table.bounds.height - clip.bounds.height))
            guard abs(target - clip.bounds.minY) > (force ? 1 : 40) else { return }
            navigationAnchorID = rows[row].id
            cancelFollow()
            if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scroll.reflectScrolledClipView(clip)
                return
            }
            followStart = clip.bounds.minY
            followTarget = target
            followStarted = ProcessInfo.processInfo.systemUptime
            let timer = Timer(
                timeInterval: 1.0 / 120.0, target: self, selector: #selector(advanceFollow), userInfo: nil,
                repeats: true)
            followTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        @objc private func advanceFollow() {
            guard let scroll = table?.enclosingScrollView else {
                cancelFollow()
                return
            }
            let fraction = min(1, max(0, (ProcessInfo.processInfo.systemUptime - followStarted) / 0.25))
            let eased = 1 - pow(1 - fraction, 3)
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: followStart + (followTarget - followStart) * eased))
            scroll.reflectScrolledClipView(clip)
            if fraction >= 1 { cancelFollow() }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Native table styles inset columns. Keys use the actual cell width,
            // not the wider scroll document, so wrapped final lines stay visible.
            guard measurementKeys.indices.contains(row) else { return 28 }
            let estimate =
                duplicateRowIndices[rows[row].id] == nil
                ? appliedHeights[rows[row].id] : duplicateAppliedHeights[row]
            let height = heights.height(for: measurementKeys[row]) ?? estimate ?? 44
            appliedHeights[rows[row].id] = height
            if duplicateRowIndices[rows[row].id] != nil { duplicateAppliedHeights[row] = height }
            return height
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TranscriptNativeRowView()
            view.isPlaybackRow = activeRows.contains(row)
            view.isReviewTarget = rows[row].id == parent.initialRowID
            return view
        }
        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            (rowView as? TranscriptNativeRowView)?.isPlaybackRow = activeRows.contains(row)
            (rowView as? TranscriptNativeRowView)?.isReviewTarget = rows[row].id == parent.initialRowID
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("transcript-cell")
            let cell =
                tableView.makeView(withIdentifier: id, owner: nil) as? TranscriptNativeCell ?? TranscriptNativeCell()
            cell.identifier = id
            let value = rows[row]
            configure(cell, for: value)
            return cell
        }
        func configure(_ cell: TranscriptNativeCell, for value: TranscriptDisplayRow) {
            // A field editor must commit to its captured segment before this
            // reusable cell is rebound to a different row.
            if cell === editedCell && cell.rowID != value.id { finishEdit() }
            cell.configure(colored(value), showsSpeakers: parent.showsSpeakers)
            cell.isPlaybackRow = activeRows.contains { rows[$0].id == value.id }
            cell.allowsEditing = parent.editable
            cell.body.delegate = self
            cell.play = parent.canPlay ? { [weak self] in self?.parent.play(value.start) } : nil
            cell.editText = { [weak self] in self?.edit(id: value.id) }
            cell.userInteracted = { [weak self] in self?.userSelected() }
            cell.assignSpeaker =
                parent.editable && value.canAssignPerson
                ? { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    self.showSpeaker(value, cell: cell)
                } : nil
        }
        private func registerSpeakerColors(_ rows: [TranscriptDisplayRow]) {
            for row in rows {
                if let slot = row.speakerColorIndex {
                    speakerColors[row.speakerColorKey ?? row.speakerID?.uuidString ?? row.speaker] = slot
                }
            }
            speakerColors = TranscriptSpeakerPalette.indices(
                for: rows.filter { $0.speakerColorIndex == nil }.map {
                    $0.speakerColorKey ?? $0.speakerID?.uuidString ?? $0.speaker
                }, preserving: speakerColors)
        }
        private func colored(_ row: TranscriptDisplayRow) -> TranscriptDisplayRow {
            var result = row
            if result.speakerColorIndex == nil {
                result.speakerColorIndex =
                    speakerColors[row.speakerColorKey ?? row.speakerID?.uuidString ?? row.speaker]
            }
            return result
        }
        func widthChanged() {
            cancelFollow()
            scheduleLayout()
        }
        private func scheduleLayout() {
            layoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settleLayout() }
            layoutWork = work
            DispatchQueue.main.async(execute: work)
        }
        private func withoutLayoutAnimation(_ action: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                action()
            }
        }
        func settleLayout() {
            // Reloading an AppKit table detaches its shared field editor. Live
            // updates are coalesced until the person finishes their edit.
            guard editedID == nil, parent.followsLive == nil || popover?.isShown != true else { return }
            guard let table, let scroll = table.enclosingScrollView,
                scroll.contentView.bounds.width > 1, scroll.contentView.bounds.height > 1
            else { return }
            layoutWork?.cancel()
            layoutWork = nil
            cancelFollow()
            let visibleRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            let offset = visibleRow >= 0 ? scroll.contentView.bounds.minY - table.rect(ofRow: visibleRow).minY : 0
            withoutLayoutAnimation {
                // Columns can settle to a new width while document bounds stay unchanged.
                let scale = table.window?.backingScaleFactor ?? 1
                let width = TranscriptTextMeasurement.normalizedTextWidth(
                    table.tableColumns.first?.width ?? table.bounds.width, showsSpeakers: parent.showsSpeakers,
                    scale: scale)
                if settledWidth != width || settledScale != scale {
                    // Invalidate geometry without rebuilding unchanged cells.
                    // The surrounding context disables implicit row animation.
                    rebuildMeasurementKeys(indexesChanged: false)
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
                    settledWidth = width
                    settledScale = scale
                }
                if parent.followsLive == true, !liveFollowPaused {
                    needsInitialPosition = false
                    scroll.contentView.scroll(
                        to: NSPoint(
                            x: 0, y: max(0, table.bounds.height - scroll.contentView.bounds.height)))
                }
                else if needsInitialPosition {
                    // Saved rows can arrive after the first layout. Keep an
                    // explicit navigation request pending until its row exists.
                    if let initialRowID = parent.initialRowID,
                        !rows.contains(where: { $0.id == initialRowID })
                    {
                        return
                    }
                    needsInitialPosition = false
                    if let initialRowID = parent.initialRowID,
                        let row = rows.firstIndex(where: { $0.id == initialRowID })
                    {
                        let target = min(
                            max(0, table.rect(ofRow: row).minY - scroll.contentView.bounds.height * 0.3),
                            max(0, table.bounds.height - scroll.contentView.bounds.height))
                        navigationAnchorID = initialRowID
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        userScrollUntil = ProcessInfo.processInfo.systemUptime + 4
                    }
                    else if let activeRow {
                        navigationAnchorID = rows[activeRow].id
                        followActiveRow(force: true, animated: false)
                    }
                    else {
                        scroll.contentView.scroll(to: .zero)
                    }
                }
                else if rows.indices.contains(visibleRow) {
                    let target = max(
                        0,
                        min(
                            table.rect(ofRow: visibleRow).minY + offset,
                            table.bounds.height - scroll.contentView.bounds.height))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            scheduleMeasurements()
        }
        private func rebuildMeasurementKeys(from boundary: Int = 0, indexesChanged: Bool = true) {
            guard let table else {
                measurementKeys = []
                return
            }
            let width = TranscriptTextMeasurement.normalizedTextWidth(
                table.tableColumns.first?.width ?? table.bounds.width, showsSpeakers: parent.showsSpeakers,
                scale: table.window?.backingScaleFactor ?? 1)
            let boundary = min(boundary, rows.count, measurementKeys.count)
            if indexesChanged {
                duplicateAppliedHeights = duplicateAppliedHeights.filter { $0.key < boundary }
            }
            if boundary == 0 && indexesChanged {
                rowIndices.removeAll(keepingCapacity: true)
                duplicateRowIndices.removeAll(keepingCapacity: true)
            }
            measurementKeys.replaceSubrange(
                boundary...,
                with: rows[boundary...].enumerated().map {
                    let index = boundary + $0.offset
                    let row = $0.element
                    if indexesChanged {
                        if rowIndices[row.id] == nil {
                            rowIndices[row.id] = index
                        }
                        else {
                            duplicateRowIndices[row.id, default: []].append(index)
                        }
                    }
                    return TranscriptMeasurementKey(
                        meetingID: parent.meetingID ?? fallbackMeetingID, rowID: row.id,
                        textRevision: row.textRevision, effectiveWidth: width, typographyVersion: 1,
                        layoutVersion: parent.showsSpeakers ? 2 : 1)
                })
        }
        private func activateMeasurements() {
            heights.activate(pageID, retry: { [weak self] in self?.scheduleMeasurements() }) {
                [weak self] keys in self?.publishMeasurements(keys)
            }
        }
        private func scheduleMeasurements() {
            guard let clip = table?.enclosingScrollView?.contentView else { return }
            if clipObserver == nil {
                clip.postsBoundsChangedNotifications = true
                clipObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleMeasurements() } }
            }
            guard measurementWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.measurementWork = nil
                self.requestVisibleMeasurements()
            }
            measurementWork = work
            DispatchQueue.main.async(execute: work)
        }
        func requestVisibleMeasurements() {
            guard heights.isAvailable(to: pageID) else { return }
            activateMeasurements()
            guard let table, !rows.isEmpty, measurementKeys.count == rows.count else { return }
            var visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            var start = min(rows.count, visible.location)
            var end = min(rows.count, start + max(1, visible.length))
            var nearby = max(0, start - 8)..<min(rows.count, end + 8)
            var order = Array(start..<end) + nearby.filter { $0 < start || $0 >= end }
            publishMeasurements(Set(order.map { measurementKeys[$0] }))
            visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            start = min(rows.count, visible.location)
            end = min(rows.count, start + max(1, visible.length))
            nearby = max(0, start - 8)..<min(rows.count, end + 8)
            order = Array(start..<end) + nearby.filter { $0 < start || $0 >= end }
            if let anchor = navigationAnchorID, let index = rowIndices[anchor], (start..<end).contains(index),
                editedID == nil, !scrollerTracking, parent.followsLive == nil || popover?.isShown != true,
                order.allSatisfy({ row in
                    guard let height = heights.height(for: measurementKeys[row]) else { return false }
                    return height
                        == (duplicateRowIndices[rows[row].id] == nil
                            ? appliedHeights[rows[row].id] : duplicateAppliedHeights[row])
                })
            {
                navigationAnchorID = nil
            }
            heights.request(
                order.map { TranscriptMeasurementInput(key: measurementKeys[$0], text: rows[$0].text) },
                owner: pageID)
        }
        private func publishMeasurements(_ keys: Set<TranscriptMeasurementKey>) {
            guard let table, let scroll = table.enclosingScrollView, editedID == nil, !scrollerTracking,
                parent.followsLive == nil || popover?.isShown != true
            else { return }
            // The current key includes meeting, revision, width, and typography.
            var changed = IndexSet()
            for key in keys {
                let indices = rowIndices[key.rowID].map { [$0] } ?? []
                for index in indices + (duplicateRowIndices[key.rowID] ?? []) {
                    let applied =
                        duplicateRowIndices[key.rowID] == nil
                        ? appliedHeights[key.rowID] : duplicateAppliedHeights[index]
                    guard measurementKeys[index] == key, let height = heights.height(for: key), height != applied
                    else { continue }
                    changed.insert(index)
                }
            }
            guard !changed.isEmpty else { return }
            let signposter = TranscriptLayoutMetrics.signposter
            let state = signposter.beginInterval("Transcript height publication", id: signposter.makeSignpostID())
            defer { signposter.endInterval("Transcript height publication", state) }
            let first = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            let wasFollowing = followTimer != nil
            let visible = table.rows(in: table.visibleRect)
            var navigationRow = navigationAnchorID.flatMap { rowIndices[$0] }
            if let row = navigationRow, !wasFollowing,
                visible.location == NSNotFound || !NSLocationInRange(row, visible)
            {
                navigationAnchorID = nil
                navigationRow = nil
            }
            let anchorIndex = navigationRow ?? first
            let anchor = rows.indices.contains(anchorIndex) ? rows[anchorIndex].id : nil
            let offset = anchorIndex >= 0 ? scroll.contentView.bounds.minY - table.rect(ofRow: anchorIndex).minY : 0
            cancelFollow()
            withoutLayoutAnimation {
                table.noteHeightOfRows(withIndexesChanged: changed)
                for index in changed {
                    let height = heights.height(for: measurementKeys[index])
                    appliedHeights[rows[index].id] = height
                    if duplicateRowIndices[rows[index].id] != nil { duplicateAppliedHeights[index] = height }
                }
                if parent.followsLive == true, !liveFollowPaused {
                    scroll.contentView.scroll(
                        to: NSPoint(x: 0, y: max(0, table.bounds.height - scroll.contentView.bounds.height)))
                }
                else if let anchor, let index = rowIndices[anchor] {
                    let y = min(
                        max(0, table.rect(ofRow: index).minY + offset),
                        max(0, table.bounds.height - scroll.contentView.bounds.height))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                }
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            // Finish an interrupted seek using corrected geometry. Replaying the
            // old animation target can otherwise strand a paused seek offscreen.
            if wasFollowing {
                navigationAnchorID = activeRow.map { rows[$0].id }
                followActiveRow(force: true, animated: false)
            }
            scheduleMeasurements()
        }
        @objc func clicked(_ sender: NSTableView) {
            pendingClick?.cancel()
            guard rows.indices.contains(sender.clickedRow), parent.canPlay else { return }
            let start = rows[sender.clickedRow].start
            let work = DispatchWorkItem { [weak self] in self?.parent.play(start) }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
        @objc func doubleClicked(_ sender: NSTableView) {
            pendingClick?.cancel()
            let row = sender.clickedRow
            guard rows.indices.contains(row),
                let cell = sender.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptNativeCell
            else { return }
            let point = NSApp.currentEvent.map { cell.convert($0.locationInWindow, from: nil) } ?? .zero
            let value = rows[row]
            let assigning = parent.showsSpeakers && cell.badge.frame.contains(point)
            // NSTableView finishes its mouse tracking after this action returns.
            // Activate the editor after that phase so the table cannot reclaim it.
            DispatchQueue.main.async { [weak self, weak cell] in
                guard let self, let cell, cell.rowID == value.id else { return }
                if assigning {
                    self.showSpeaker(value, cell: cell)
                }
                else {
                    self.edit(id: value.id)
                }
            }
        }
        func showSpeaker(_ row: TranscriptDisplayRow, cell: TranscriptNativeCell) {
            guard parent.editable, row.canAssignPerson, let speakerID = row.speakerID else { return }
            pauseLiveFollow()
            finishEdit()
            cancelFollow()
            popover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(
                rootView: parent.speakerPicker(speakerID) { [weak popover] in popover?.close() })
            self.popover = popover
            popover.show(relativeTo: cell.badge.bounds, of: cell.badge, preferredEdge: .maxY)
        }
        func popoverDidClose(_ notification: Notification) {
            applyDeferredLiveUpdate()
            scheduleLayout()
        }
        func edit(id: UUID) { if let index = rows.firstIndex(where: { $0.id == id }) { edit(row: index) } }
        func edit(row: Int) {
            pendingClick?.cancel()
            guard parent.editable, rows.indices.contains(row), let table else { return }
            finishEdit()
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptNativeCell else {
                return
            }
            let value = rows[row]
            beginEdit(cell, value: value)
        }
        func beginEdit(_ cell: TranscriptNativeCell, value: TranscriptDisplayRow) {
            navigationAnchorID = nil
            pauseLiveFollow()
            cancelFollow()
            finishEdit()
            editedID = value.id
            editedCell = cell
            let save = parent.save
            let capturedSave = parent.captureSave?(value.id)
            editSession.begin(text: value.text) { text in
                if let capturedSave {
                    capturedSave(text)
                }
                else {
                    save(value.id, text)
                }
            }
            cell.body.isEditable = true
            cell.body.isSelectable = true
            cell.body.stringValue = editSession.draft
            cell.body.selectText(nil)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === editedCell?.body else { return }
            editSession.draft = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === editedCell?.body else { return }
            finishEdit()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishEdit(cancel: true)
                table?.window?.makeFirstResponder(table)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finishEdit()
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }
        func finishEdit(cancel: Bool = false) {
            guard editedID != nil else { return }
            let cell = editedCell
            if let cell, cell.rowID == editedID {
                editSession.draft = (cell.body.currentEditor() as? NSTextView)?.string ?? cell.body.stringValue
            }
            editedID = nil
            editedCell = nil
            cell?.body.isEditable = false
            cell?.body.isSelectable = false
            editSession.finish(cancel: cancel)
            if cancel, let id = cell?.rowID, let row = rows.first(where: { $0.id == id }) {
                cell?.configure(colored(row), showsSpeakers: parent.showsSpeakers)
            }
            applyDeferredLiveUpdate()
            scheduleLayout()
        }
        private func applyDeferredLiveUpdate() {
            if deferredLiveUpdate != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let pending = self.deferredLiveUpdate else { return }
                    self.deferredLiveUpdate = nil
                    self.update(pending)
                }
            }
        }
    }
}

@MainActor final class TranscriptNativeScroller: NSScroller {
    // Native drawing and action tracking support either system scroller style.
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var userScrolled: (() -> Void)?
    var trackingChanged: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        trackingChanged?(true)
        defer { trackingChanged?(false) }
        super.mouseDown(with: event)
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        userScrolled?()
        let sent = super.sendAction(action, to: target)
        userScrolled?()
        return sent
    }
}

@MainActor final class TranscriptNativeScrollView: NSScrollView {
    var willScroll: (() -> Void)?
    var viewportChanged: (() -> Void)?
    private var previousViewportSize = NSSize.zero
    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        guard size != previousViewportSize else { return }
        previousViewportSize = size
        viewportChanged?()
    }
    override func scrollWheel(with event: NSEvent) {
        willScroll?()
        super.scrollWheel(with: event)
    }
}

@MainActor class TranscriptNativeTable: NSTableView {
    var widthChanged: (() -> Void)?
    var editSelected: (() -> Void)?
    var userInteracted: (() -> Void)?
    private var lastWidth: CGFloat = 0
    private(set) var hoverEnabled = false
    private var hoverWork: DispatchWorkItem?
    private var hoverDeadline: TimeInterval = 0
    private(set) var keyboardSelection = false
    private var handlingPointerSelection = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            keyboardSelection = !handlingPointerSelection
            redrawVisibleRows()
        }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            keyboardSelection = false
            redrawVisibleRows()
        }
        return accepted
    }
    func delayHover() {
        hoverDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        if hoverEnabled {
            hoverEnabled = false
            redrawVisibleRows()
        }
        // Wheel and momentum events only extend a deadline. Do not invalidate
        // every visible row or allocate another work item for each event.
        guard hoverWork == nil else { return }
        scheduleHoverCheck(after: 0.15)
    }
    private func scheduleHoverCheck(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            let remaining = self.hoverDeadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                self.scheduleHoverCheck(after: remaining)
            }
            else {
                self.hoverEnabled = true
                self.redrawVisibleRows()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func redrawVisibleRows() {
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }
    override func layout() {
        super.layout()
        let width = tableColumns.first?.width ?? bounds.width
        guard width > 0, width != lastWidth else { return }
        lastWidth = width
        DispatchQueue.main.async { [weak self] in self?.widthChanged?() }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        widthChanged?()
    }
    override func keyDown(with event: NSEvent) {
        userInteracted?()
        keyboardSelection = true
        if event.keyCode == 36 {
            editSelected?()
        }
        else {
            super.keyDown(with: event)
        }
        redrawVisibleRows()
    }
    override func mouseDown(with event: NSEvent) {
        userInteracted?()
        keyboardSelection = false
        handlingPointerSelection = true
        defer {
            handlingPointerSelection = false
            redrawVisibleRows()
        }
        super.mouseDown(with: event)
    }
}

@MainActor final class TranscriptNativeRowView: NSTableRowView {
    var isReviewTarget = false {
        didSet { if oldValue != isReviewTarget { needsDisplay = true } }
    }
    var isPlaybackRow = false {
        didSet { if oldValue != isPlaybackRow { updatePlaybackFill(animated: true) } }
    }
    private let playbackFill = CAShapeLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playbackFill.fillColor = NSColor.clear.cgColor
        layer?.insertSublayer(playbackFill, at: 0)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        playbackFill.frame = bounds
        playbackFill.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 5, cornerHeight: 5, transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlaybackFill(animated: false)
    }
    private func updatePlaybackFill(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let target = NSColor.controlAccentColor.withAlphaComponent(isPlaybackRow ? 0.12 : 0).cgColor
            let previous = playbackFill.presentation()?.fillColor ?? playbackFill.fillColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playbackFill.fillColor = target
            CATransaction.commit()
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "fillColor")
                animation.fromValue = previous
                animation.toValue = target
                animation.duration = 0.18
                playbackFill.add(animation, forKey: "playbackFill")
            }
        }
        needsDisplay = true
    }
    private var tracking: NSTrackingArea?
    private var table: TranscriptNativeTable? {
        var view = superview
        while let current = view {
            if let table = current as? TranscriptNativeTable { return table }
            view = current.superview
        }
        return nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) {
        table?.delayHover()
    }
    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isSelected, let table, table.keyboardSelection, window?.firstResponder === table {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            outline.fill()
            NSColor.keyboardFocusIndicatorColor.setStroke()
            outline.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
            outline.stroke()
        }
        if isReviewTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1
            outline.stroke()
        }
        let pointerInside =
            window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        let highlight = table?.hoverEnabled == true && pointerInside
        guard highlight && !isPlaybackRow else { return }
        NSColor.labelColor.withAlphaComponent(0.065).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// Resolve semantic colors during drawing, rather than caching a CGColor before
/// the reused cell has joined a window with its effective appearance.
enum TranscriptSpeakerPalette {
    static func displayKey(personID: UUID?, track: String, label: String) -> String {
        if let personID { return personID.uuidString }
        let source = track.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized: String
        switch source {
        case "mic", "microphone": normalized = "microphone"
        case "sys", "system", "system audio": normalized = "system"
        default: normalized = source
        }
        return "\(normalized):\(label)"
    }

    static func index(for key: String) -> Int {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Int(hash % 8)
    }
    static func indices(for keys: [String], preserving previous: [String: Int] = [:]) -> [String: Int] {
        var result = previous
        var used = Set(previous.values)
        for key in Set(keys).sorted() where result[key] == nil {
            var slot = 0
            while used.contains(slot) { slot += 1 }
            result[key] = slot
            used.insert(slot)
        }
        return result
    }

    static func foreground(for tint: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let source = tint.usingColorSpace(.sRGB) ?? tint
                resolved = source.blended(withFraction: 0.45, of: isDark ? .white : .black) ?? .labelColor
            }
            return resolved
        }
    }
    static func color(for key: String, index: Int? = nil) -> NSColor {
        let slot = max(0, index ?? self.index(for: key))
        let semantic: [NSColor] = [
            .systemTeal, .systemPink, .systemPurple, .systemOrange, .systemBlue, .systemGreen, .systemIndigo,
            .systemBrown,
        ]
        if slot < semantic.count { return semantic[slot] }
        let hue = (Double(slot - semantic.count + 1) * 0.618033988749895).truncatingRemainder(dividingBy: 1)
        return NSColor(calibratedHue: hue, saturation: 0.68, brightness: 0.78, alpha: 1)
    }
}

@MainActor final class TranscriptSpeakerBadge: NSView {
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var unresolved = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
        tint.withAlphaComponent(0.12).setFill()
        path.fill()
        if unresolved {
            TranscriptSpeakerPalette.foreground(for: tint).withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.lineCapStyle = .round
            path.setLineDash([1, 3], count: 2, phase: 0)
            path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor final class TranscriptNativeCell: NSTableCellView {
    let time = NSTextField(labelWithString: "")
    let badge = TranscriptSpeakerBadge()
    let speaker = NSTextField(wrappingLabelWithString: "")
    let body = NSTextField()
    var rowID: UUID?
    var editText: (() -> Void)?
    var assignSpeaker: (() -> Void)? {
        didSet {
            speaker.setAccessibilityCustomActions(
                assignSpeaker == nil
                    ? []
                    : [
                        NSAccessibilityCustomAction(
                            name: "Assign Person", target: self, selector: #selector(accessibilityAssign))
                    ])
        }
    }
    var play: (() -> Void)? {
        didSet { updatePlaybackAccessibility() }
    }
    var allowsEditing = false
    var userInteracted: (() -> Void)?
    private var showsSpeakers = false
    private var speakerHeight: CGFloat = 20
    private var speakerWidth: CGFloat = 100
    var isPlaybackRow = false {
        didSet {
            time.textColor = isPlaybackRow ? .controlAccentColor : .secondaryLabelColor
            body.textColor = .labelColor
        }
    }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        speaker.font = .systemFont(ofSize: 11, weight: .medium)
        speaker.maximumNumberOfLines = 1
        speaker.lineBreakMode = .byTruncatingTail
        speaker.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 13)
        body.isBordered = false
        body.drawsBackground = false
        body.isEditable = false
        body.isSelectable = false
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        addSubview(time)
        addSubview(badge)
        badge.addSubview(speaker)
        addSubview(body)
        body.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Edit Transcript", target: self, selector: #selector(accessibilityEdit))
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ row: TranscriptDisplayRow, showsSpeakers: Bool) {
        rowID = row.id
        self.showsSpeakers = showsSpeakers
        time.stringValue = TranscriptRow<Text>.timestamp(row.start)
        updatePlaybackAccessibility()
        speaker.stringValue = row.speaker
        speakerHeight = 20
        speakerWidth = min(100, ceil((row.speaker as NSString).size(withAttributes: [.font: speaker.font!]).width) + 16)
        let colorKey = row.personID?.uuidString ?? row.speakerID?.uuidString ?? row.speaker
        badge.tint = TranscriptSpeakerPalette.color(for: colorKey, index: row.speakerColorIndex)
        badge.unresolved = row.personID == nil && !row.isSourcePlaceholder
        speaker.textColor = TranscriptSpeakerPalette.foreground(for: badge.tint)
        if !body.isEditable {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
            let text = NSMutableAttributedString(string: row.text, attributes: attributes)
            if row.isProvisional {
                for range in row.provisionalTextRanges ?? [NSRange(location: 0, length: text.length)]
                where range.location >= 0 && range.length > 0
                    && range.location <= text.length && range.length <= text.length - range.location
                {
                    text.addAttributes(
                        [
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: NSColor.tertiaryLabelColor,
                        ], range: range)
                }
            }
            if row.isProvisional {
                for (index, range) in row.recentWordRanges.enumerated()
                where range.location >= 0 && range.length > 0
                    && range.location <= text.length && range.length <= text.length - range.location
                {
                    text.addAttribute(
                        .foregroundColor,
                        value: index == row.recentWordRanges.count - 1
                            ? NSColor(Color.red) : TranscriptLiveWordColor.trailing, range: range)
                }
            }
            body.attributedStringValue = text
            body.setAccessibilityHelp(row.accessibilityHelp ?? (row.isProvisional ? "Transcription may change." : nil))
        }
        badge.isHidden = !showsSpeakers || row.speaker.isEmpty
        badge.needsDisplay = true
        needsLayout = true
    }
    override func layout() {
        super.layout()
        time.frame = NSRect(x: 4, y: 5, width: 68, height: 20)
        badge.frame = NSRect(
            x: 84, y: 4, width: speakerWidth, height: min(bounds.height - 8, max(20, speakerHeight)))
        speaker.frame = badge.bounds.insetBy(dx: 6, dy: 2)
        let left: CGFloat = showsSpeakers ? 196 : 84
        let width = TranscriptTextMeasurement.normalizedTextWidth(
            bounds.width, showsSpeakers: showsSpeakers, scale: window?.backingScaleFactor ?? 1)
        body.frame = NSRect(x: left, y: 4, width: width, height: max(20, bounds.height - 8))
    }
    private func updatePlaybackAccessibility() {
        time.setAccessibilityLabel(play == nil ? time.stringValue : "Play from \(time.stringValue)")
        time.setAccessibilityCustomActions(
            play == nil
                ? []
                : [
                    NSAccessibilityCustomAction(name: "Play", target: self, selector: #selector(accessibilityPlay))
                ])
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if body.isEditable, body.frame.contains(point) { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) { enclosingTable?.mouseDown(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? {
        userInteracted?()
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Text", action: #selector(copyText), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        if allowsEditing {
            let edit = NSMenuItem(title: "Edit Transcript", action: #selector(accessibilityEdit), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            if showsSpeakers && assignSpeaker != nil {
                let assign = NSMenuItem(
                    title: "Assign Person", action: #selector(accessibilityAssign), keyEquivalent: "")
                assign.target = self
                menu.addItem(assign)
            }
        }
        return menu
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        badge.needsDisplay = true
    }
    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body.stringValue, forType: .string)
    }
    private var enclosingTable: NSTableView? {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }
    @objc private func accessibilityEdit() -> Bool {
        editText?()
        return true
    }
    @objc private func accessibilityPlay() -> Bool {
        play?()
        return play != nil
    }
    @objc private func accessibilityAssign() -> Bool {
        assignSpeaker?()
        return assignSpeaker != nil
    }
}

/// Preserve the original live trail's public SwiftUI color mix in native text.
enum TranscriptLiveWordColor {
    static var trailing: NSColor {
        NSColor(Color.red.mix(with: .primary, by: 0.5))
    }
}

/// A revised partial may change its identity or split into several rows. Replace
/// only that suffix, leaving the preceding native cells and scroll anchor intact.
struct TranscriptRowUpdate {
    let removed: IndexSet
    let inserted: IndexSet
    let changed: IndexSet

    init(previous: [TranscriptDisplayRow], current: [TranscriptDisplayRow], offset: Int = 0) {
        var prefix = 0
        let common = min(previous.count, current.count)
        while prefix < common, previous[prefix].id == current[prefix].id { prefix += 1 }
        removed = IndexSet((offset + prefix)..<(offset + previous.count))
        inserted = IndexSet((offset + prefix)..<(offset + current.count))
        changed = IndexSet((0..<prefix).filter { previous[$0] != current[$0] }.map { offset + $0 })
    }
}
