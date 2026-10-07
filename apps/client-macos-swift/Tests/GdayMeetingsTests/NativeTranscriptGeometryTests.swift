import AppKit
import Darwin
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeTranscriptGeometryTests {
    /// Matched work probe; callback timing is not presented-frame latency.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_TRANSCRIPT_REVISION_PERFORMANCE"] == "1"))
    func warmRevisionPerformance() async throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        let shortRows = (0..<1000).map { index in
            TranscriptDisplayRow(
                id: UUID(), start: Double(index), end: Double(index + 1),
                speaker: "Speaker", speakerID: nil, text: "Synthetic short passage.")
        }
        view.rows = shortRows
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let longRow = TranscriptDisplayRow(
            id: shortRows[0].id, start: 0, end: 1,
            speaker: "Speaker", speakerID: nil, text: String(repeating: "Synthetic wrapping passage. ", count: 50))
        view.rows[0] = longRow
        fixture.coordinator.update(view)
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let clip = fixture.scroll.contentView
        fixture.coordinator.userScrolled()
        clip.scroll(to: NSPoint(x: 0, y: fixture.table.rect(ofRow: 40).minY + 7))
        fixture.scroll.reflectScrolledClipView(clip)
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let service = fixture.coordinator.heights
        let measured = service.statistics.measurements
        let start = PerformanceResourceSnapshot.capture()
        var heapStart = malloc_statistics_t()
        malloc_zone_statistics(nil, &heapStart)
        var actions: [Double] = []
        var gaps: [Double] = []
        var last = ProcessInfo.processInfo.systemUptime
        var drifted = 0
        for index in 0..<240 {
            try await Task.sleep(for: .milliseconds(16))
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append(now - last)
            last = now
            let row = fixture.table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
            let offset = clip.bounds.minY - fixture.table.rect(ofRow: row).minY
            view.rows[0] = index.isMultiple(of: 2) ? shortRows[0] : longRow
            fixture.coordinator.update(view)
            fixture.coordinator.settleLayout()
            fixture.coordinator.requestVisibleMeasurements()
            await service.waitUntilIdle()
            let after = fixture.table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
            if after != row || abs(clip.bounds.minY - fixture.table.rect(ofRow: after).minY - offset) >= 1 {
                drifted += 1
            }
            actions.append(ProcessInfo.processInfo.systemUptime - now)
        }
        let end = PerformanceResourceSnapshot.capture()
        var heapEnd = malloc_statistics_t()
        malloc_zone_statistics(nil, &heapEnd)
        let report: [String: Any] = [
            "operations": actions.count, "rows": shortRows.count, "drifted_updates": drifted,
            "process_cpu_s": end.processCPUSeconds - start.processCPUSeconds,
            "main_cpu_s": end.mainCPUSeconds - start.mainCPUSeconds,
            "elapsed_s": end.monotonicSeconds - start.monotonicSeconds,
            "action_p95_s": actions.sorted()[227], "action_max_s": actions.max() ?? 0,
            "callback_gaps_over_100ms": gaps.filter { $0 > 0.1 }.count,
            "heap_live_blocks_delta": Int64(heapEnd.blocks_in_use) - Int64(heapStart.blocks_in_use),
            "heap_live_bytes_delta": Int64(heapEnd.size_in_use) - Int64(heapStart.size_in_use),
            "heap_reserved_bytes_delta": Int64(heapEnd.size_allocated) - Int64(heapStart.size_allocated),
            "additional_measurements": service.statistics.measurements - measured,
            "cache_hits": service.statistics.hits, "cache_entries": service.entryCount,
            "pending_count": service.pendingCount, "peak_pending_count": service.statistics.peakPendingCount,
            "peak_pending_bytes": service.statistics.peakPendingBytes,
        ]
        print(
            "PERF_WARM_REVISION "
                + String(
                    decoding:
                        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        #expect(actions.count == 240)
        #expect(service.pendingCount == 0)
    }

    @Test func independentReviewWarmRevisionAboveViewportPreservesReadingAnchor() async {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        let initialRows = (0..<100).map { index in
            TranscriptDisplayRow(
                id: UUID(), start: Double(index), end: Double(index + 1),
                speaker: "Speaker", speakerID: nil, text: "Synthetic short passage.")
        }
        view.rows = initialRows
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        view.rows[0] = TranscriptDisplayRow(
            id: initialRows[0].id, start: 0, end: 1,
            speaker: "Speaker", speakerID: nil, text: String(repeating: "Synthetic wrapping passage. ", count: 50))
        fixture.coordinator.update(view)
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let clip = fixture.scroll.contentView
        fixture.coordinator.userScrolled()
        clip.scroll(to: NSPoint(x: 0, y: fixture.table.rect(ofRow: 40).minY + 7))
        fixture.scroll.reflectScrolledClipView(clip)
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let before = fixture.table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
        let offset = clip.bounds.minY - fixture.table.rect(ofRow: before).minY
        // Restore a cached text revision above the reader's viewport.
        view.rows[0] = initialRows[0]
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let after = fixture.table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
        #expect(view.rows[after].id == view.rows[before].id)
        #expect(abs(clip.bounds.minY - fixture.table.rect(ofRow: after).minY - offset) < 1)
    }

    @Test func columnWidthChangesInvalidateNativeRowGeometry() async throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = syntheticRows()
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        fixture.table.layoutSubtreeIfNeeded()
        let bounds = fixture.table.bounds.width
        let previous = fixture.table.rect(ofRow: 0).height
        fixture.column.width = 570
        fixture.table.layoutSubtreeIfNeeded()
        #expect(fixture.table.bounds.width == bounds)
        #expect(fixture.column.width == 570)
        fixture.coordinator.widthChanged()
        fixture.coordinator.settleLayout()
        #expect(
            fixture.coordinator.tableView(fixture.table, heightOfRow: 0) == previous,
            "A width-only change must keep the last estimate until its measurement arrives")
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        fixture.table.layoutSubtreeIfNeeded()
        for index in view.rows.indices {
            let actual = fixture.table.rect(ofRow: index).height
            let expected = nativeHeight(
                view.rows[index].text, width: fixture.column.width, scale: fixture.window.backingScaleFactor)
            #expect(actual == expected, "Actual column width must determine row geometry")
        }
        #expect(fixture.table.rect(ofRow: 0).height < previous)
    }

    @Test func sourceReplacementDuringColumnSettlingHasNoStaleRowGaps() async throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = (0..<40).flatMap { _ in syntheticRows() }
        fixture.column.width = 570
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let bounds = fixture.table.bounds.width
        fixture.column.width = 310
        view.meetingID = UUID()
        view.generation += 1
        view.rows = syntheticRows()
        fixture.coordinator.update(view)
        _ = fixture.table.rect(ofRow: 2)  // Materialize AppKit's intermediate geometry.
        fixture.column.width = 570
        fixture.table.layoutSubtreeIfNeeded()
        #expect(fixture.table.bounds.width == bounds)
        fixture.coordinator.widthChanged()
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        fixture.table.layoutSubtreeIfNeeded()
        for index in view.rows.indices {
            let actual = fixture.table.rect(ofRow: index).height
            let expected = nativeHeight(
                view.rows[index].text, width: fixture.column.width, scale: fixture.window.backingScaleFactor)
            #expect(actual == expected, "Changing meetings must not retain intermediate-width row heights")
        }
    }

    @Test func partialRevisionDuringWidthChangeInvalidatesUnchangedRows() async {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = syntheticRows()
        fixture.column.width = 570
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let wide = fixture.table.rect(ofRow: 0).height
        fixture.column.width = 310
        view.rows[2] = TranscriptDisplayRow(
            id: view.rows[2].id, start: 2, end: 3, speaker: "Speaker", speakerID: nil, text: "Edited short row.")
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        #expect(fixture.table.rect(ofRow: 0).height > wide)
        #expect(
            fixture.table.rect(ofRow: 0).height
                == nativeHeight(view.rows[0].text, width: 310, scale: fixture.window.backingScaleFactor))
    }

    @Test func revisedRowsKeepTheirPreviousHeightUntilMeasurementAndResumeAfterEditing() async throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = syntheticRows()
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        let previous = fixture.coordinator.tableView(fixture.table, heightOfRow: 0)
        view.rows[0] = TranscriptDisplayRow(
            id: view.rows[0].id, start: 0, end: 1, speaker: "Speaker", speakerID: nil,
            text: String(repeating: "A longer revised synthetic paragraph. ", count: 15))
        fixture.coordinator.update(view)
        #expect(fixture.coordinator.tableView(fixture.table, heightOfRow: 0) == previous)
        let cell = try #require(fixture.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptNativeCell)
        fixture.coordinator.beginEdit(cell, value: view.rows[0])
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        #expect(fixture.table.rect(ofRow: 0).height == previous)
        fixture.coordinator.finishEdit(cancel: true)
        fixture.coordinator.requestVisibleMeasurements()
        #expect(fixture.table.rect(ofRow: 0).height > previous)
    }

    @Test func duplicateRowIDsKeepIndependentGeometry() async {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        let id = UUID()
        view.rows = [
            TranscriptDisplayRow(id: id, start: 0, end: 1, speaker: "Speaker", speakerID: nil, text: "Short"),
            TranscriptDisplayRow(
                id: id, start: 1, end: 2, speaker: "Speaker", speakerID: nil,
                text: String(repeating: "Synthetic wrapping text. ", count: 12)),
        ]
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.coordinator.requestVisibleMeasurements()
        await fixture.coordinator.heights.waitUntilIdle()
        #expect(fixture.table.rect(ofRow: 1).height > fixture.table.rect(ofRow: 0).height)
    }

    private func nativeHeight(_ text: String, width: CGFloat, scale: CGFloat) -> CGFloat {
        let textWidth = TranscriptTextMeasurement.normalizedTextWidth(width, showsSpeakers: true, scale: scale)
        let field = TranscriptNativeCell().body
        field.stringValue = text
        let size = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100_000))
        return max(20, ceil(size.height) + 2) + 8
    }

    private func syntheticRows() -> [TranscriptDisplayRow] {
        [
            String(repeating: "A synthetic paragraph with words that wrap. ", count: 6),
            String(repeating: "这是一段用于检查换行的示例文字。", count: 8),
            "Short passage.",
        ].enumerated().map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0.offset), end: Double($0.offset + 1), speaker: "Speaker",
                speakerID: nil, text: $0.element)
        }
    }
}

@MainActor private final class GeometryFixture {
    let window: NSWindow
    let scroll: TranscriptNativeScrollView
    let table: TranscriptNativeTable
    let column: NSTableColumn
    let view: NativeTranscriptView
    let coordinator: NativeTranscriptView.Coordinator
    init() {
        view = NativeTranscriptView(
            rows: [], generation: 1, showsSpeakers: true, editable: true, canPlay: true,
            meetingID: UUID(), play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        coordinator = NativeTranscriptView.Coordinator(view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = TranscriptNativeScrollView(frame: window.contentView!.bounds)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table = TranscriptNativeTable(frame: scroll.bounds)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.usesAutomaticRowHeights = false
        column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = coordinator
        table.dataSource = coordinator
        coordinator.table = table
        table.widthChanged = { [weak coordinator] in coordinator?.widthChanged() }
        scroll.viewportChanged = { [weak coordinator] in coordinator?.widthChanged() }
        scroll.documentView = table
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func close() {
        coordinator.tearDown()
        window.close()
    }
}
