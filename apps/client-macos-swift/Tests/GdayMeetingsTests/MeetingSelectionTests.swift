import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

private final class MeetingSelectionReads: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var completions = 0
    func record() { lock.withLock { starts += 1 } }
    func finish() { lock.withLock { completions += 1 } }
    var count: Int { lock.withLock { starts } }
    var completedCount: Int { lock.withLock { completions } }
}

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
        let reads = MeetingSelectionReads()
        store.meetingLoadReader = { id, root in
            reads.record()
            defer { reads.finish() }
            return try MeetingFolderStorage.read(id: id, directory: root)
        }
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
            var lastPoll = ContinuousClock.now
            var longestGap = Duration.zero
            var longestLayout = Duration.zero
            let loaded = try await waitForMainActorTestCondition {
                let started = ContinuousClock.now
                longestGap = max(longestGap, lastPoll.duration(to: started))
                window.contentView?.layoutSubtreeIfNeeded()
                longestLayout = max(longestLayout, started.duration(to: .now))
                lastPoll = .now
                return store.meeting(id: id) != nil
            }
            let coordinator = list.delegate as? NativeMeetingList.Coordinator
            #expect(
                loaded,
                "Selected row \(list.selectedRow), correct binding \(coordinator?.parent.selection == id), reads \(reads.completedCount)/\(reads.count), poll gap \(longestGap), layout \(longestLayout), operations \(store.meetingLoadOperations.count), pending \(store.meetingLoadQueue.pendingCount), error \(String(describing: store.meetingPageError))"
            )
            #expect(playback.meetingID == nil)
            #expect(!playback.isPlaying)
        }
    }
}
