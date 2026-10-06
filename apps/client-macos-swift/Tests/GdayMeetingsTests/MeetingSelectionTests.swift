import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor @Suite(.serialized)
struct MeetingSelectionTests {
    @Test func selectingUncachedMeetingLoadsDetailWithoutPlayback() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let meetings = [Meeting(title: "First meeting"), Meeting(title: "Second meeting")]
        for meeting in meetings { try MeetingFolderStorage.write(meeting, directory: directory) }
        try LibraryIndex(directory: directory).rebuild()
        let store = MeetingStore(dataDirectory: directory)
        let playback = MeetingPlayback()
        let indexed = try await waitForMainActorTestCondition(timeout: .seconds(10)) {
            store.visibleMeetingEntries.count == meetings.count
        }
        #expect(indexed)
        #expect(store.meetings.isEmpty)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LibraryView().environmentObject(store).environmentObject(playback))
        defer { window.close() }
        func table(in view: NSView) -> MeetingNativeTable? {
            (view as? MeetingNativeTable) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let mounted = try await waitForMainActorTestCondition {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView.flatMap { table(in: $0) }?.numberOfRows ?? 0 >= meetings.count
        }
        #expect(mounted)
        let list = try #require(window.contentView.flatMap { table(in: $0) })
        // Use the native selection notification shared by pointer and keyboard navigation.
        // Neither selection invokes the table's double-click playback action.
        for row in 0..<meetings.count {
            let id = store.visibleMeetingEntries[row].id
            #expect(store.meeting(id: id) == nil)
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let loaded = try await waitForMainActorTestCondition {
                window.contentView?.layoutSubtreeIfNeeded()
                return store.meeting(id: id) != nil
            }
            #expect(loaded, "Selecting an uncached meeting must mount its detail loader")
            #expect(playback.meetingID == nil)
            #expect(!playback.isPlaying)
        }
    }
}
