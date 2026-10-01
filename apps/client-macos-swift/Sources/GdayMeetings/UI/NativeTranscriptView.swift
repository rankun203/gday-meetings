import AppKit
import Combine
import SwiftUI

struct TranscriptDisplayRow: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let speaker: String
    let speakerID: UUID?
    let text: String
    var personID: UUID? = nil
    var speakerColorIndex: Int? = nil
    var isProvisional = false
    var recentWordRanges: [NSRange] = []
    var accessibilityHelp: String? = nil
}

/// One selected transcript, reusable native rows, and the window's shared field
/// editor. Scrolling performs no store lookups, file reads, or SwiftUI row builds.
struct NativeTranscriptView: NSViewRepresentable {
    var rows: [TranscriptDisplayRow]
    var generation: Int
    var showsSpeakers: Bool
    var editable: Bool
    var canPlay: Bool
    var playback: MeetingPlayback? = nil
    var meetingID: UUID? = nil
    var transcriptSourceID: UUID? = nil
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
        var heights = TranscriptHeightCache()
        var pendingClick: DispatchWorkItem?
        var popover: NSPopover?
        private var playbackSubscription: AnyCancellable?
        private var lastSeekRevision: UInt64?
        private var needsInitialPosition = true
        private var layoutWork: DispatchWorkItem?
        private var settledWidth: CGFloat?
        private var followTimer: Timer?
        private var followStarted: TimeInterval = 0
        private var followStart: CGFloat = 0
        private var followTarget: CGFloat = 0
        private var userScrollUntil: TimeInterval = 0
        private weak var observedPlayback: MeetingPlayback?
        private var playbackOrder: [(start: Double, row: Int)] = []
        private(set) var activeRow: Int?
        private var editedID: UUID?
        private weak var editedCell: TranscriptNativeCell?
        private let editSession = TranscriptEditSession()
        private var deferredLiveUpdate: NativeTranscriptView?
        private var liveFollowPaused = false

        init(_ parent: NativeTranscriptView) { self.parent = parent }
        func update(_ value: NativeTranscriptView) {
            let sourceChanged =
                parent.meetingID != value.meetingID
                || parent.transcriptSourceID != value.transcriptSourceID || generation == nil
            let presentationChanged =
                parent.showsSpeakers != value.showsSpeakers
                || parent.editable != value.editable || parent.canPlay != value.canPlay
            let changed = sourceChanged || presentationChanged || rows != value.rows
            let followChanged = parent.followsLive != value.followsLive
            if followChanged, value.followsLive == true { liveFollowPaused = false }
            if !sourceChanged, value.followsLive != nil, editedID != nil || popover?.isShown == true {
                deferredLiveUpdate = value
                return
            }
            parent = value
            deferredLiveUpdate = nil
            guard changed, let table else {
                observePlayback()
                refreshPlayback()
                if followChanged { scheduleLayout() }
                return
            }
            cancelFollow()
            if sourceChanged {
                deferredLiveUpdate = nil
                liveFollowPaused = false
                needsInitialPosition = true
                userScrollUntil = 0
                popover?.close()
            }
            pendingClick?.cancel()
            let selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            finishEdit()
            // Unchanged cells survive a partial reload. Clear the previous
            // highlight while its index still refers to the old row set.
            updatePlayback(meetingID: nil, time: 0, follows: false)
            let previousRows = rows
            rows = value.rows
            playbackOrder = rows.enumerated().filter { $0.element.start.isFinite }.map { ($0.element.start, $0.offset) }
                .sorted { $0.start == $1.start ? $0.row < $1.row : $0.start < $1.start }
            generation = value.generation
            heights.removeMissingIDs(Set(rows.map(\.id)))
            activeRow = nil
            withoutLayoutAnimation {
                let commonCount = min(previousRows.count, rows.count)
                let samePrefix = previousRows.prefix(commonCount).map(\.id) == rows.prefix(commonCount).map(\.id)
                if sourceChanged || presentationChanged || !samePrefix {
                    table.reloadData()
                }
                else {
                    if rows.count > previousRows.count {
                        table.insertRows(at: IndexSet(previousRows.count..<rows.count), withAnimation: [])
                    }
                    else if rows.count < previousRows.count {
                        table.removeRows(at: IndexSet(rows.count..<previousRows.count), withAnimation: [])
                    }
                    let changedRows = IndexSet((0..<commonCount).filter { previousRows[$0] != rows[$0] })
                    if !changedRows.isEmpty {
                        table.reloadData(
                            forRowIndexes: changedRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                        table.noteHeightOfRows(withIndexesChanged: changedRows)
                    }
                }
            }
            observePlayback()
            refreshPlayback()
            scheduleLayout()
            if let selection, let index = rows.firstIndex(where: { $0.id == selection }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
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
                if low > 0 { next = playbackOrder[low - 1].row }
            }
            guard next != activeRow else { return }
            let previous = activeRow
            activeRow = next
            if next == nil { cancelFollow() }
            for row in [previous, next].compactMap({ $0 }) {
                if let view = table?.rowView(atRow: row, makeIfNecessary: false) as? TranscriptNativeRowView {
                    view.isPlaybackRow = row == next
                }
                (table?.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptNativeCell)?.isPlaybackRow =
                    row == next
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
        }
        func userScrolled() {
            pauseLiveFollow()
            userScrollUntil = ProcessInfo.processInfo.systemUptime + 4
            cancelFollow()
        }
        func userSelected() {
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
            guard abs(target - clip.bounds.minY) > 40 else { return }
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
            // Native table styles inset columns. Measure the actual cell width,
            // not the wider scroll document, so wrapped final lines stay visible.
            heights.height(
                rows[row], width: tableView.tableColumns.first?.width ?? tableView.bounds.width,
                showsSpeakers: parent.showsSpeakers)
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TranscriptNativeRowView()
            view.isPlaybackRow = row == activeRow
            return view
        }
        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            (rowView as? TranscriptNativeRowView)?.isPlaybackRow = row == activeRow
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
            cell.configure(value, showsSpeakers: parent.showsSpeakers)
            cell.isPlaybackRow = activeRow.map { rows[$0].id == value.id } ?? false
            cell.allowsEditing = parent.editable
            cell.body.delegate = self
            cell.play = parent.canPlay ? { [weak self] in self?.parent.play(value.start) } : nil
            cell.editText = { [weak self] in self?.edit(id: value.id) }
            cell.userInteracted = { [weak self] in self?.userSelected() }
            cell.assignSpeaker = { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.showSpeaker(value, cell: cell)
            }
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
                let width = table.bounds.width.rounded(.down)
                if settledWidth != width {
                    // noteHeightOfRows schedules per-row geometry transitions inside
                    // AppKit. A synchronous reload has no row movement animation.
                    table.reloadData()
                    table.layoutSubtreeIfNeeded()
                    settledWidth = width
                }
                if parent.followsLive == true, !liveFollowPaused {
                    needsInitialPosition = false
                    scroll.contentView.scroll(
                        to: NSPoint(
                            x: 0, y: max(0, table.bounds.height - scroll.contentView.bounds.height)))
                }
                else if needsInitialPosition {
                    needsInitialPosition = false
                    if activeRow != nil {
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
            guard parent.editable, let speakerID = row.speakerID else { return }
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
            pauseLiveFollow()
            cancelFollow()
            finishEdit()
            editedID = value.id
            editedCell = cell
            let save = parent.save
            editSession.begin(text: value.text) { save(value.id, $0) }
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
                cell?.configure(row, showsSpeakers: parent.showsSpeakers)
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

@MainActor final class TranscriptHeightCache {
    private struct Entry {
        var text: String
        var speaker: String
        var width: CGFloat
        var height: CGFloat
    }
    private var values: [UUID: Entry] = [:]
    private(set) var measurements = 0
    func height(_ row: TranscriptDisplayRow, width: CGFloat, showsSpeakers: Bool) -> CGFloat {
        let textWidth = max(40, width - 8 - 68 - 12 - (showsSpeakers ? 112 : 0))
        let speaker = showsSpeakers ? row.speaker : ""
        if let value = values[row.id], value.text == row.text, value.speaker == speaker, value.width == textWidth {
            return value.height
        }
        let text = Self.measure(row.text, width: textWidth - 4, font: .systemFont(ofSize: 13)) + 2
        let name =
            showsSpeakers ? 20.0 : 0
        let result = max(20, text, name) + 8
        measurements += 1
        values[row.id] = Entry(text: row.text, speaker: speaker, width: textWidth, height: result)
        return result
    }
    func removeMissingIDs(_ ids: Set<UUID>) { values = values.filter { ids.contains($0.key) } }
    private static func measure(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil(
            (text as NSString).boundingRect(
                with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
            ).height)
    }
}

@MainActor final class TranscriptNativeScroller: NSScroller {
    var userScrolled: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        userScrolled?()
        super.mouseDown(with: event)
        userScrolled?()
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
        let width = bounds.width.rounded(.down)
        guard width > 0, width != lastWidth else { return }
        lastWidth = width
        DispatchQueue.main.async { [weak self] in self?.widthChanged?() }
    }
    override func keyDown(with event: NSEvent) {
        userInteracted?()
        if event.keyCode == 36 {
            editSelected?()
        }
        else {
            super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        userInteracted?()
        super.mouseDown(with: event)
    }
}

@MainActor final class TranscriptNativeRowView: NSTableRowView {
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
    static func indices(for keys: [String]) -> [String: Int] {
        // Color depends only on identity, never on which other speakers are present.
        Dictionary(Set(keys).map { ($0, index(for: $0)) }, uniquingKeysWith: { first, _ in first })
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
        [
            .systemTeal, .systemPink, .systemPurple, .systemOrange, .systemBlue, .systemGreen, .systemIndigo,
            .systemBrown,
        ][index ?? self.index(for: key)]
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
    var assignSpeaker: (() -> Void)?
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
            body.textColor = isPlaybackRow ? .labelColor : .secondaryLabelColor
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
        speaker.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Assign Person", target: self, selector: #selector(accessibilityAssign))
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
        badge.unresolved = row.personID == nil
        speaker.textColor = TranscriptSpeakerPalette.foreground(for: badge.tint)
        if !body.isEditable {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
            if row.isProvisional {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = NSColor.tertiaryLabelColor
            }
            let text = NSMutableAttributedString(string: row.text, attributes: attributes)
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
        badge.isHidden = !showsSpeakers
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
        body.frame = NSRect(x: left, y: 4, width: max(40, bounds.width - left - 4), height: max(20, bounds.height - 8))
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
            if showsSpeakers {
                let assign = NSMenuItem(
                    title: "Assign Person", action: #selector(accessibilityAssign), keyEquivalent: "")
                assign.target = self
                menu.addItem(assign)
            }
        }
        return menu
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
        return true
    }
}

/// Preserve the original live trail's public SwiftUI color mix in native text.
enum TranscriptLiveWordColor {
    static var trailing: NSColor {
        if #available(macOS 15, *) { return NSColor(Color.red.mix(with: .primary, by: 0.5)) }
        return NSColor.systemRed.blended(withFraction: 0.5, of: .labelColor) ?? .systemRed
    }
}
