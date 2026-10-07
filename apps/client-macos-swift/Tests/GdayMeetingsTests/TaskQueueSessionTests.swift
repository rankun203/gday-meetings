import Foundation
import Testing

@testable import GdayMeetings

struct TaskQueueSessionTests {
    private func row(_ title: String) -> TaskHistoryRow {
        .managed(.init(kind: .summary, meetingID: UUID(), meetingTitle: title, state: .completed))
    }

    @MainActor @Test func emptyFilterClearsSelectionAndDetail() {
        let session = TaskQueueSession()
        session.select(row("Synthetic summary"))
        session.failureOffset = 20
        let token = session.beginPageLoad()
        session.applyPage([], token: token)
        session.finishPageLoad(token)
        #expect(session.rows.isEmpty)
        #expect(session.selection == nil)
        #expect(session.selectedRow == nil)
        #expect(session.failureOffset == 0)
        #expect(!session.loadingPage)
    }

    @MainActor @Test func refreshRetainsSelectionOrChoosesNearestRemainingRow() {
        let session = TaskQueueSession()
        let first = row("First task")
        let middle = row("Selected task")
        let last = row("Next task")
        session.select(middle)
        var token = session.beginPageLoad()
        session.applyPage([first, middle, last], token: token)
        session.finishPageLoad(token)
        #expect(session.selectedRow?.id == middle.id)
        token = session.beginPageLoad()
        session.applyPage([first, last], token: token, preferredPosition: 1)
        session.finishPageLoad(token)
        #expect(session.selection == last.id)
        #expect(session.selectedRow?.id == last.id)
    }

    @MainActor @Test func scopeTransitionRetainsMatchingSelectionWhileHidingOldDetail() {
        let session = TaskQueueSession()
        let retained = row("Selected task")
        session.select(retained)
        session.resetPagePresentation()
        #expect(session.selection == retained.id)
        #expect(session.selectedRow == nil)
        let token = session.beginPageLoad()
        session.applyPage([row("First task"), retained], token: token)
        session.finishPageLoad(token)
        #expect(session.selection == retained.id)
        #expect(session.selectedRow?.id == retained.id)
    }

    @MainActor @Test func staleCompletionCannotPublishOrClearNewerLoad() {
        let session = TaskQueueSession()
        let oldToken = session.beginPageLoad()
        let newToken = session.beginPageLoad()
        session.applyPage([row("Abandoned page")], token: oldToken)
        session.finishPageLoad(oldToken)
        #expect(session.rows.isEmpty)
        #expect(session.loadingPage)
        session.applyPage([row("Current page")], token: newToken)
        session.finishPageLoad(newToken)
        #expect(session.rows.count == 1)
        #expect(!session.loadingPage)
    }

    private actor PageGate {
        var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor @Test func cancelledPageRetiresWithoutBlockingReplacement() async {
        let session = TaskQueueSession()
        let gate = PageGate()
        let token = session.beginPageLoad()
        let oldPage = row("Old page")
        let operation = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            await gate.wait()
            guard !Task.isCancelled else { return }
            session.applyPage([oldPage], token: token)
        }
        session.pageLoadTask = operation
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !gate.isWaiting, clock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        session.cancelPageLoad()
        #expect(operation.isCancelled)
        #expect(!session.loadingPage)
        let replacement = session.beginPageLoad()
        await gate.release()
        await operation.value
        #expect(session.rows.isEmpty)
        #expect(session.loadingPage)
        session.finishPageLoad(replacement)
        #expect(!session.loadingPage)
    }

    @MainActor @Test func revisionRefreshWaitsForRequestedFocus() async {
        let session = TaskQueueSession()
        let target = row("Requested task")
        let gate = PageGate()
        let token = session.beginFocusLoad(target.id)
        let operation = Task { @MainActor in
            await gate.wait()
            session.applyPage([row("Other task"), target], token: token)
            session.select(target)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !gate.isWaiting, clock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        #expect(session.deferRefreshUntilFocusCompletes())
        #expect(session.deferRefreshUntilFocusCompletes())
        #expect(session.generation == token)
        #expect(session.pendingFocusID == target.id)
        await gate.release()
        await operation.value
        #expect(session.finishFocusLoad(token))
        #expect(session.selection == target.id)
        #expect(session.pendingFocusID == nil)
        #expect(!session.loadingPage)
        #expect(!session.deferRefreshUntilFocusCompletes())
    }

    @Test func growingFailuresExposeNextPageWithoutStateTransition() {
        var failures = Dictionary(
            uniqueKeysWithValues: (0..<20).map { (String(format: "%04d", $0), "Synthetic error") })
        #expect(!TaskFailurePage(failures: failures, offset: 0).hasNext)
        failures["0020"] = "Synthetic error"
        let first = TaskFailurePage(failures: failures, offset: 0)
        #expect(first.count == 21)
        #expect(first.entries.count == 20)
        #expect(first.hasNext)
        let next = TaskFailurePage(failures: failures, offset: 20)
        #expect(next.entries.map(\.key) == ["0020"])
        #expect(next.hasPrevious)
        #expect(!next.hasNext)
    }

    @Test func failureContextResolutionIsBoundedAndRemovedPagesClamp() {
        let failures = Dictionary(
            uniqueKeysWithValues: (0..<1001).map { (String(format: "%04d", $0), "Repeated error") })
        let page = TaskFailurePage(failures: failures, offset: 980)
        var resolved: [String] = []
        let values = page.resolve { key, message in
            resolved.append(key)
            return message
        }
        #expect(resolved == (980..<1000).map { String(format: "%04d", $0) })
        #expect(values.count == 20)
        #expect(page.hasNext)
        let smaller = TaskFailurePage(failures: ["0000": "Error"], offset: 980)
        #expect(smaller.offset == 0)
        #expect(smaller.entries.count == 1)
        #expect(!smaller.hasPrevious)
        #expect(!smaller.hasNext)
        let empty = TaskFailurePage(failures: [:], offset: 20)
        #expect(empty.offset == 0)
        #expect(empty.entries.isEmpty)
    }
}
