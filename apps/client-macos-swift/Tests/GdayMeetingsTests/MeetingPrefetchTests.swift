import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor @Suite(.serialized)
struct MeetingPrefetchTests {
    @Test func newRecordingRevealOverridesThePreviousViewportAnchor() throws {
        _ = NSApplication.shared
        let values = (0..<30).map { number in
            MeetingListEntry(
                Meeting(title: "Meeting \(number)", createdAt: Date(timeIntervalSince1970: Double(30 - number))))
        }
        var list = makeList(values)
        let coordinator = list.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 450))
        let table = MeetingNativeTable(frame: scroll.bounds)
        table.style = .inset
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("meeting")))
        table.delegate = coordinator
        table.dataSource = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        coordinator.update(list)
        table.layoutSubtreeIfNeeded()
        let originalOffset = scroll.contentView.bounds.minY
        let recording = MeetingListEntry(Meeting(title: "Synthetic recording"))
        list = makeList([recording] + values, selection: recording.id)
        list.recordingID = recording.id
        coordinator.update(list)
        // Selection alone retains the old first row and leaves the recording above it.
        #expect(scroll.contentView.bounds.minY > originalOffset + 40)
        list.revealID = recording.id
        coordinator.update(list)
        #expect(table.selectedRow == 0)
        #expect(scroll.contentView.bounds.minY <= table.rect(ofRow: 0).minY)
        #expect(scroll.contentView.bounds.maxY >= table.rect(ofRow: 0).maxY)
        let revealedOffset = scroll.contentView.bounds.minY
        list.entries[0].title = "Updated synthetic recording"
        list.isFinalizing = true
        coordinator.update(list)
        #expect(abs(scroll.contentView.bounds.minY - revealedOffset) < 0.5)
    }

    @Test func nativeWindowRotationPreservesVisibleMeetingAndPixelOffset() throws {
        _ = NSApplication.shared
        let values = (0..<1200).map { number in
            MeetingListEntry(
                Meeting(title: "Meeting \(number)", createdAt: Date(timeIntervalSince1970: Double(1200 - number))))
        }
        var list = makeList(Array(values.prefix(800)))
        let coordinator = list.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 450))
        let table = MeetingNativeTable(frame: NSRect(x: 0, y: 0, width: 300, height: 450))
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("meeting")))
        table.delegate = coordinator
        table.dataSource = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        coordinator.update(list)
        table.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 720).minY + 17))
        let original = anchor(table: table, scroll: scroll, rows: coordinator.rows)
        list.entries = Array(values[200..<1000])
        coordinator.update(list)
        let forward = anchor(table: table, scroll: scroll, rows: coordinator.rows)
        #expect(forward.0 == original.0)
        #expect(abs(forward.1 - original.1) < 0.5)
        list.entries = Array(values.prefix(800))
        coordinator.update(list)
        let backwards = anchor(table: table, scroll: scroll, rows: coordinator.rows)
        #expect(backwards.0 == original.0)
        #expect(abs(backwards.1 - original.1) < 0.5)
    }

    @Test func prefetchStartsBeforeBoundaryAndTraversesWindowInBothDirections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try LibraryIndex(directory: root)
        let values = (0..<1600).map { number in
            MeetingListEntry(
                Meeting(title: "Meeting \(number)", createdAt: Date(timeIntervalSince1970: Double(1600 - number))))
        }
        for entry in values { try index.upsert(entry) }
        try JSONEncoder().encode(UInt64.max).write(to: root.appendingPathComponent(".index-events.json"))
        let store = MeetingStore(dataDirectory: root)
        store.libraryMonitor = nil
        store.libraryIndex = index
        store.resetMeetingPages()
        #expect(store.meetingCatalog.count == 20)
        store.prefetchMeetings(.init(firstID: values[0].id, lastID: values[7].id, visibleCount: 8, rowsPerSecond: 0))
        try await wait(store)
        #expect(store.meetingCatalog.count >= 60)
        #expect(store.meetings.isEmpty)
        for _ in 0..<12 {
            let rows = store.meetingCatalog
            let first = max(0, rows.count - 80)
            let last = min(rows.count - 1, first + 8)
            store.prefetchMeetings(
                .init(firstID: rows[first].id, lastID: rows[last].id, visibleCount: 9, rowsPerSecond: 220))
            try await wait(store)
        }
        #expect(store.meetingPageHasPrevious)
        #expect(store.meetingCatalog.count <= 1000)
        let advanced = try #require(store.meetingCatalog.first)
        #expect(advanced.id != values[0].id)
        for _ in 0..<12 where store.meetingPageHasPrevious {
            let rows = store.meetingCatalog
            store.prefetchMeetings(
                .init(firstID: rows[10].id, lastID: rows[18].id, visibleCount: 9, rowsPerSecond: -220))
            try await wait(store)
        }
        #expect(store.meetingCatalog.first?.id == values.first?.id)
        #expect(!store.meetingPageHasPrevious)
        #expect(store.meetingPageError == nil)
        let current = store.meetingCatalog
        store.prefetchMeetings(
            .init(
                firstID: current[current.count - 10].id,
                lastID: current.last!.id, visibleCount: 10, rowsPerSecond: 220))
        await store.searchMeetingPages("no such meeting")
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.meetingCatalog.isEmpty)
        #expect(!store.isLoadingMeetingPage)
        #expect(store.meetingPrefetch.task == nil)
    }

    private func wait(_ store: MeetingStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isLoadingMeetingPage && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isLoadingMeetingPage)
    }
    private func anchor(table: NSTableView, scroll: NSScrollView, rows: [MeetingListEntry]) -> (UUID?, CGFloat) {
        let row = table.rows(in: scroll.contentView.bounds).location
        return (
            rows.indices.contains(row) ? rows[row].id : nil,
            scroll.contentView.bounds.minY - table.rect(ofRow: row).minY
        )
    }
    private func makeList(_ rows: [MeetingListEntry], selection: UUID? = nil) -> NativeMeetingList {
        NativeMeetingList(
            entries: rows, selection: .constant(selection), recordingID: nil, isFinalizing: false,
            playingID: nil, isPlaying: false, canPlay: true, archiveStatuses: [:], viewportChanged: { _ in },
            play: { _ in }, reveal: { _ in }, export: { _ in }, delete: { _ in })
    }
}
