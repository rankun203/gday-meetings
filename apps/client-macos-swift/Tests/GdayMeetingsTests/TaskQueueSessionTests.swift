import Foundation
import Testing

@testable import GdayMeetings

struct TaskQueueSessionTests {
    @MainActor @Test func returningToTasksPreservesSelectionUntilAnotherExplicitFocusRequest() {
        let session = TaskQueueSession()
        let target = UUID()
        let firstRequest = UUID()
        session.receiveFocusRequest(firstRequest)
        #expect(session.handledFocusRequest == firstRequest)
        session.handledFocusID = target
        let laterSelection = UUID()
        session.selection = laterSelection
        session.scope = .paused

        session.receiveFocusRequest(firstRequest)
        #expect(session.handledFocusID == target)
        #expect(session.selection == laterSelection)
        #expect(session.scope == .paused)

        session.receiveFocusRequest(UUID())
        #expect(session.handledFocusID == nil)
        #expect(session.selection == laterSelection)
        #expect(session.scope == .paused)
        session.handledFocusID = target
        session.receiveFocusRequest(nil)
        #expect(session.handledFocusID == target)
    }

    @MainActor @Test func revisionNotificationsLetAnInFlightPageFinish() async {
        let session = TaskQueueSession()
        let gate = PageGate()
        let token = session.beginPageLoad()
        let loaded = row("Loaded task")
        var replacementLoads = 0
        let page = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            await gate.wait()
            session.applyPage([loaded], token: token)
        }
        session.pageLoadTask = page
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !gate.isWaiting, clock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        for _ in 0..<50 {
            session.refreshWhenIdle {
                replacementLoads += 1
                _ = session.beginPageLoad()
            }
        }
        #expect(!page.isCancelled)
        #expect(session.generation == token)
        #expect(replacementLoads == 0)
        await gate.release()
        await page.value
        #expect(session.rows == [loaded])
        #expect(!session.loadingPage)
        session.refreshWhenIdle { replacementLoads += 1 }
        #expect(replacementLoads == 1)
    }

    @MainActor @Test func refreshRetainsOffWindowDetailsUntilTheSelectionIsRemovedOrFiltered() {
        let session = TaskQueueSession()
        let selected = row("Selected task")
        let remaining = row("Remaining task")
        var token = session.beginPageLoad()
        session.applyPage([selected, remaining], token: token)
        session.select(selected)
        session.replacePageRows([remaining], retainingCursors: true)
        session.viewport.anchor = .init(id: remaining.id, offset: 7)
        token = session.beginPageLoad()
        session.applyPage([remaining], token: token, retainingSelection: selected)
        #expect(session.selection == selected.id)
        #expect(session.selectedRow == selected)
        #expect(session.rows == [remaining])
        #expect(session.viewport.anchor?.id == remaining.id)
        #expect(session.viewport.anchor?.offset == 7)
        #expect(session.revealID == nil)
        token = session.beginPageLoad()
        session.applyPage([remaining], token: token, retainingSelection: nil)
        #expect(session.selection == remaining.id)
        #expect(session.selectedRow == remaining)
    }

    @MainActor @Test(arguments: [false, true])
    func revealingAMovingTargetRetriesOnceAndThenStops(movesAgain: Bool) async {
        let session = TaskQueueSession()
        let initial = row("Moving target")
        var current = initial
        var requested: [ManagedTaskJournal.DisplayCursor] = []
        let token = session.beginFocusLoad(initial.id)
        let result = await session.loadStableReveal(target: initial, token: token, currentTarget: { current }) {
            target in
            requested.append(target.displayCursor)
            if requested.count == 1 || movesAgain {
                guard case .managed(var changed) = current else { return target.id }
                changed.timeline = [
                    .init(kind: .resumed, date: .distantFuture.addingTimeInterval(Double(requested.count)), reason: nil)
                ]
                current = .managed(changed)
            }
            await Task.yield()
            return target.id
        }
        #expect(requested.count == 2)
        #expect(requested.first == initial.displayCursor)
        #expect(requested.last != initial.displayCursor)
        if movesAgain {
            #expect(result == nil)
        }
        else {
            #expect(result?.target == current)
        }
        _ = session.finishFocusLoad(token)
        #expect(!session.loadingPage)
    }

    @MainActor @Test(arguments: [false, true])
    func staleOrCancelledRevealCannotPublishAResult(cancel: Bool) async {
        let session = TaskQueueSession()
        let gate = PageGate()
        let target = row("Requested task")
        let token = session.beginFocusLoad(target.id)
        let operation = Task { @MainActor in
            defer { _ = session.finishFocusLoad(token) }
            return await session.loadStableReveal(target: target, token: token, currentTarget: { target }) { _ in
                await gate.wait()
                return [target]
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !gate.isWaiting, clock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        if cancel {
            operation.cancel()
        }
        else {
            session.cancelPageLoad()
        }
        await gate.release()
        #expect(await operation.value == nil)
        #expect(session.rows.isEmpty)
        #expect(session.pendingFocusID == nil)
        #expect(!session.loadingPage)
    }

    private enum ActionInterruption: CaseIterable, Sendable {
        case none, selection, navigation, cancellation
    }

    @MainActor @Test(arguments: ActionInterruption.allCases)
    private func suspendedActionPreservesUserNavigationAndFinishesMutation(interruption: ActionInterruption) async {
        let session = TaskQueueSession()
        let selected = row("Selected historical task")
        let other = row("Different task")
        session.select(selected)
        let gate = PageGate()
        var mutationFinished = false
        let operation = Task { @MainActor in
            await session.performTaskAction(id: selected.id) {
                await gate.wait()
                mutationFinished = true
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !gate.isWaiting, clock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        #expect(session.deferRefreshUntilFocusCompletes())
        #expect(session.selectedRow?.id == selected.id)
        switch interruption {
        case .none: break
        case .selection: session.select(other)
        case .navigation: session.cancelPageLoad()
        case .cancellation: operation.cancel()
        }
        await gate.release()
        let reveal = await operation.value
        #expect(mutationFinished)
        #expect(session.pendingFocusID == nil)
        #expect(!session.loadingPage)
        switch interruption {
        case .none: #expect(reveal == true)
        case .selection:
            #expect(reveal == false)
            #expect(session.selectedRow?.id == other.id)
        case .navigation, .cancellation: #expect(reveal == nil)
        }
    }

    @MainActor @Test func changingFilterClearsThePreviousCountWhileLoading() {
        let session = TaskQueueSession()
        session.totalCount = 42
        session.scope = .attention
        session.resetPagePresentation()
        #expect(session.totalCount == 0)
        #expect(session.rows.isEmpty)
    }

    @MainActor @Test func selectingStatusOrTypeUsesOneFilterAtATime() {
        let session = TaskQueueSession()
        session.scope = .paused
        #expect(session.query == .init(status: .paused))
        session.taskType = .findVoices
        #expect(session.scope == .all)
        #expect(session.query == .init(type: .findVoices))
        session.scope = .failed
        #expect(session.taskType == .all)
        #expect(session.query == .init(status: .failed))
        session.showAllTasks()
        #expect(session.query == .init())
    }

    @MainActor @Test func pageCursorsRetainAppliedBoundariesDuringLiveTransitions() {
        let session = TaskQueueSession()
        let first = row("First task")
        let last = row("Last task")
        let token = session.beginPageLoad()
        session.applyPage([first, last], token: token)
        session.finishPageLoad(token)
        let firstCursor = session.firstDisplayCursor
        let lastCursor = session.lastDisplayCursor
        guard case .managed(var changed) = first else { return }
        changed.timeline = [.init(kind: .paused, date: .distantFuture, reason: nil)]
        session.rows[0] = .managed(changed)
        #expect(session.firstDisplayCursor == firstCursor)
        #expect(session.lastDisplayCursor == lastCursor)
        session.replacePageRows(session.rows + [row("Additional task")], retainingCursors: true)
        #expect(session.firstDisplayCursor == firstCursor)
        let replacement = session.beginPageLoad()
        session.applyPage(session.rows, token: replacement)
        #expect(session.firstDisplayCursor == TaskHistoryRow.managed(changed).displayCursor)
        session.resetPagePresentation()
        #expect(session.firstDisplayCursor == nil)
        #expect(session.lastDisplayCursor == nil)
    }

    @MainActor @Test func selectedTransitionCanBeRevealedWhileScrolledAwaySelectionStaysUnforced() {
        let session = TaskQueueSession()
        let selected = row("Selected task")
        let other = row("Another task")
        let token = session.beginPageLoad()
        session.applyPage([selected, other], token: token)
        session.select(selected)
        guard case .managed(var changed) = selected else { return }
        changed.timeline = [.init(kind: .resumed, date: .distantFuture, reason: nil)]
        #expect(session.hasMovedSinceDisplay(.managed(changed)))
        session.replacePageRows([other], retainingCursors: true)
        #expect(session.selection == selected.id)
        #expect(!session.hasMovedSinceDisplay(.managed(changed)))
    }

    @MainActor @Test(arguments: [false, true]) func cappedPageMergeMovesOverlappingTransitionToItsNewEdge(newer: Bool)
        throws
    {
        let rows = (0..<150).map { index in
            TaskHistoryRow.managed(
                .init(
                    kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic task", state: .completed,
                    createdAt: Date(timeIntervalSince1970: Double(150 - index))))
        }
        let overlapping = newer ? rows.last! : rows.first!
        guard case .managed(var transitioned) = overlapping else { return }
        transitioned.timeline = [
            .init(
                kind: .ended, date: Date(timeIntervalSince1970: newer ? 500 : -100), reason: nil)
        ]
        if !newer { transitioned.createdAt = Date(timeIntervalSince1970: -101) }
        let additional = (0..<49).map { index in
            TaskHistoryRow.managed(
                .init(
                    kind: .summary, meetingID: UUID(), meetingTitle: "Synthetic additional task", state: .completed,
                    createdAt: Date(timeIntervalSince1970: Double(newer ? 499 - index : -index))))
        }
        let incoming = newer ? [.managed(transitioned)] + additional : additional + [.managed(transitioned)]
        let merged = try #require(TaskQueueSession.mergePage(incoming, into: rows, newer: newer))
        #expect(merged.count == 150)
        #expect(Set(merged.map(\.id)).count == 150)
        #expect((newer ? merged.first?.id : merged.last?.id) == overlapping.id)
        #expect(Set(incoming.map(\.id)).isSubset(of: Set(merged.map(\.id))))
        let session = TaskQueueSession()
        let token = session.beginPageLoad()
        session.applyPage(rows, token: token)
        session.replacePageRows(merged, retainingCursors: true, replacingCursors: Set(incoming.map(\.id)))
        #expect(
            (newer ? session.firstDisplayCursor : session.lastDisplayCursor)
                == TaskHistoryRow.managed(transitioned).displayCursor)
        let protected = newer ? rows.last!.id : rows.first!.id
        // The moved overlap survives; protect a different row in the trimmed range.
        let trimmed = newer ? rows[148].id : rows[1].id
        #expect(trimmed != protected)
        #expect(TaskQueueSession.mergePage(incoming, into: rows, newer: newer, visibleFirst: trimmed) == nil)
    }

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

extension TaskQueueSessionTests {
    @MainActor @Test func maintenanceInvalidatesOnlyMatchingScopes() {
        let store = MeetingStore(
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var maintenance = ManagedTaskRecord(
            kind: .searchIndex, meetingID: UUID(), meetingTitle: "Synthetic meeting", isPreview: true, isAutomatic: true
        )
        store.invalidateTaskHistory(previous: nil, current: maintenance)
        #expect(store.managedTaskScopeRevisions[.attention, default: 0] == 0)
        #expect(store.managedTaskScopeRevisions[.all] == 1)
        #expect(store.managedTaskScopeRevisions[.maintenance] == 1)
        let before = maintenance
        maintenance.state = .failed
        maintenance.recovery = .manual
        store.invalidateTaskHistory(previous: before, current: maintenance)
        #expect(store.managedTaskScopeRevisions[.attention] == 1)
        store.invalidateTaskHistory(previous: maintenance, current: maintenance)
        #expect(store.managedTaskScopeRevisions[.attention] == 1)
        let failed = maintenance
        maintenance.attentionAcknowledged = true
        store.invalidateTaskHistory(previous: failed, current: maintenance)
        #expect(store.managedTaskScopeRevisions[.attention] == 2)
    }

    @MainActor @Test func maintenanceBatchSurvivesGapsAndEndsAfterFinalScan() {
        let store = MeetingStore(
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.updateSearchMaintenanceBatch(scanActive: true)
        #expect(!store.searchMaintenanceBatchActive)
        store.managedMaintenanceStateCounts[.queued] = 1
        store.updateSearchMaintenanceBatch()
        #expect(store.searchMaintenanceBatchActive)
        store.managedMaintenanceStateCounts[.queued] = 0
        store.updateSearchMaintenanceBatch()
        #expect(store.searchMaintenanceBatchActive)
        store.updateSearchMaintenanceBatch(scanActive: true)
        #expect(store.searchMaintenanceBatchActive)
        store.updateSearchMaintenanceBatch(scanActive: false)
        #expect(!store.searchMaintenanceBatchActive)
        store.managedMaintenanceStateCounts[.paused] = 1
        store.updateSearchMaintenanceBatch(scanActive: false)
        #expect(store.searchMaintenanceBatchActive)
    }
}
