import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor private final class TaskTableSpy: NSTableView {
    var fullReloads = 0
    var reloadedRows = IndexSet()
    override func reloadData() {
        fullReloads += 1
        super.reloadData()
    }
    override func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        reloadedRows.formUnion(rows)
        super.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }
}

struct NativeTaskListRefreshTests {
    @MainActor @Test func backgroundRefreshKeepsFooterAndReloadsOnlyChangedRow() {
        let session = TaskQueueSession()
        var task = ManagedTaskRecord(
            kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic meeting", state: .running)
        session.rows = [.managed(task)]
        session.selection = task.id
        session.hasOlder = false
        func value() -> NativeTaskList {
            NativeTaskList(
                rows: session.rows, selection: Binding(get: { session.selection }, set: { session.selection = $0 }),
                totalCount: session.footerCount(total: 1, historyLoading: false, hasHistoryError: false)
            ) { _, _, _ in }
        }
        let coordinator = NativeTaskList.Coordinator(value())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let table = TaskTableSpy()
        table.addTableColumn(NSTableColumn(identifier: .init("task")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.scroll = scroll
        coordinator.update(value())
        table.fullReloads = 0
        table.reloadedRows = []
        let token = session.beginPageLoad()
        coordinator.update(value())
        #expect(table.fullReloads == 0)
        #expect(table.reloadedRows.isEmpty)
        #expect(table.numberOfRows == 2)
        task.progress = "Writing summary…"
        session.applyPage([.managed(task)], token: token)
        session.finishPageLoad(token)
        coordinator.update(value())
        #expect(table.fullReloads == 0)
        #expect(table.reloadedRows == IndexSet(integer: 0))
        #expect(table.selectedRow == 0)
        #expect(table.numberOfRows == 2)
    }
}
