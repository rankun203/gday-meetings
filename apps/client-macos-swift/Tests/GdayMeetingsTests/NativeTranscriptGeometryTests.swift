import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeTranscriptGeometryTests {
    @Test func columnWidthChangesInvalidateNativeRowGeometry() throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = syntheticRows()
        fixture.column.width = 310
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
        fixture.table.layoutSubtreeIfNeeded()
        let bounds = fixture.table.bounds.width
        let previous = fixture.table.rect(ofRow: 0).height
        fixture.column.width = 570
        fixture.table.layoutSubtreeIfNeeded()
        #expect(fixture.table.bounds.width == bounds)
        #expect(fixture.column.width == 570)
        fixture.coordinator.widthChanged()
        fixture.coordinator.settleLayout()
        fixture.table.layoutSubtreeIfNeeded()
        let oracle = TranscriptHeightCache()
        for index in view.rows.indices {
            let actual = fixture.table.rect(ofRow: index).height
            let expected = oracle.height(view.rows[index], width: fixture.column.width, showsSpeakers: true)
            #expect(actual == expected, "Actual column width must determine row geometry")
        }
        #expect(fixture.table.rect(ofRow: 0).height < previous)
    }

    @Test func sourceReplacementDuringColumnSettlingHasNoStaleRowGaps() throws {
        let fixture = GeometryFixture()
        defer { fixture.close() }
        var view = fixture.view
        view.rows = (0..<40).flatMap { _ in syntheticRows() }
        fixture.column.width = 570
        fixture.coordinator.update(view)
        fixture.coordinator.settleLayout()
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
        fixture.table.layoutSubtreeIfNeeded()
        let oracle = TranscriptHeightCache()
        for index in view.rows.indices {
            let actual = fixture.table.rect(ofRow: index).height
            let expected = oracle.height(view.rows[index], width: fixture.column.width, showsSpeakers: true)
            #expect(actual == expected, "Changing meetings must not retain intermediate-width row heights")
        }
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
