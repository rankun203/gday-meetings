import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct WorkspaceStateTests {
    @Test func selectedMeetingTabSurvivesDestinationChangesWithoutCachingEveryMeeting() {
        let workspace = LibraryWorkspaceState()
        let first = UUID()
        workspace.selectMeeting(first)
        workspace.meetingTab = MeetingContentTab.notes.rawValue
        workspace.tasks.scope = .history
        workspace.people.query = "Example"
        workspace.selectMeeting(first)
        #expect(workspace.meetingTab == MeetingContentTab.notes.rawValue)
        workspace.selectMeeting(UUID())
        #expect(workspace.meetingTab == MeetingContentTab.transcript.rawValue)
        #expect(workspace.tasks.scope == .history)
        #expect(workspace.people.query == "Example")
    }

    @Test func directorySessionReusesItsWindowUntilScopeOrIndexChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let people = (0..<120).map { Person(name: "Person \($0)") }
        try FileEntityStorage.save(people, previous: [], kind: "people", directory: root)
        let index = try DirectoryIndex(root: root, indexDirectory: root)
        try index.reconcile(paths: [], rebuild: true)
        let session = DirectorySession()
        let revision = UUID()
        session.refresh(index: index, kind: .people, revision: revision)
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !session.page.loading }
        #expect(loaded)
        session.page.viewport(
            first: try #require(session.page.entries.suffix(10).first?.id),
            last: try #require(session.page.entries.last?.id))
        let advanced = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !session.page.loading }
        #expect(advanced)
        let ids = session.page.entries.map(\.id)
        session.viewport.anchor = .init(id: people[65].id, offset: 11)
        session.refresh(index: index, kind: .people, revision: revision)
        #expect(!session.page.loading)
        #expect(session.page.entries.map(\.id) == ids)
        #expect(session.viewport.anchor?.id == people[65].id)
        session.query = "Person 11"
        session.refresh(index: index, kind: .people, revision: revision)
        #expect(session.viewport.anchor == nil)
        let filtered = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !session.page.loading }
        #expect(filtered)
        #expect(session.page.entries.allSatisfy { $0.name.contains("Person 11") })
    }

    @Test(arguments: [CGFloat(0), CGFloat(48)])
    func nativeMeetingRemountRestoresPixelAnchorWithoutReplayingOldReveal(topInset: CGFloat) throws {
        _ = NSApplication.shared
        let retained = NativeListViewport()
        let entries = (0..<100).map { MeetingListEntry(Meeting(title: "Meeting \($0)")) }
        let view = NativeMeetingList(
            entries: entries, selection: .constant(entries[0].id), revealID: entries[0].id,
            recordingID: nil, isFinalizing: false, playingID: nil, isPlaying: false, canPlay: false,
            archiveStatuses: [:], viewportChanged: { _ in }, play: { _ in }, reveal: { _ in }, export: { _ in },
            delete: { _ in }, retainedViewport: retained)
        func mount(topInset: CGFloat) -> (NSScrollView, NativeMeetingList.Coordinator) {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.top = topInset
            let table = MeetingNativeTable(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
            table.headerView = nil
            table.addTableColumn(NSTableColumn(identifier: .init("meeting")))
            let coordinator = NativeMeetingList.Coordinator(view)
            table.dataSource = coordinator
            table.delegate = coordinator
            scroll.documentView = table
            coordinator.table = table
            coordinator.scroll = scroll
            coordinator.update(view)
            return (scroll, coordinator)
        }
        let (first, coordinator) = mount(topInset: topInset)
        first.contentView.scroll(to: NSPoint(x: 0, y: 753))
        coordinator.viewportDidChange()
        let before = try #require(retained.anchor)
        #expect(before.id != entries[0].id)
        let (second, replacement) = mount(topInset: topInset + 24)
        withExtendedLifetime(replacement) {
            #expect(
                abs(
                    (second.contentView.bounds.minY + second.contentInsets.top)
                        - (first.contentView.bounds.minY + first.contentInsets.top)) < 0.5)
            #expect(retained.anchor?.id == before.id)
            #expect(abs((retained.anchor?.offset ?? 0) - before.offset) < 0.5)
            #expect(retained.revealedID == entries[0].id)
        }
    }
}
