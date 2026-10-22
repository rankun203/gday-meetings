import Combine
import Foundation

/// Window-local state survives destination replacement without retaining hidden views.
@MainActor final class LibraryWorkspaceState: ObservableObject {
    @Published var meetingTab = 0
    private var meetingID: UUID?
    let meetingViewport = NativeListViewport()
    let tasks = TaskQueueSession()
    let people = DirectorySession()
    let tags = DirectorySession()

    func selectMeeting(_ id: UUID?) {
        guard meetingID != id else { return }
        meetingID = id
        meetingTab = 0
    }
}

/// Scroll updates do not publish SwiftUI invalidations. Each list retains one anchor.
@MainActor final class NativeListViewport {
    struct Anchor {
        let id: UUID
        let offset: CGFloat
    }
    var anchor: Anchor?
    var revealedID: UUID?
    func reset() {
        anchor = nil
        revealedID = nil
    }
}

@MainActor final class DirectorySession: ObservableObject {
    @Published var query = ""
    @Published var showExcluded = false
    let page = DirectoryPaging()
    let viewport = NativeListViewport()
    private var previousQuery = ""
    private var previousExcluded = false
    private var revision: UUID?
    private weak var index: DirectoryIndex?

    func refresh(index: DirectoryIndex?, kind: DirectoryKind, revision: UUID) {
        let excluded = kind == .tags || showExcluded
        let changedScope = query != previousQuery || excluded != previousExcluded
        guard changedScope || self.revision != revision || self.index !== index else { return }
        if changedScope { viewport.reset() }
        previousQuery = query
        previousExcluded = excluded
        self.revision = revision
        self.index = index
        page.configure(index: index, kind: kind, query: query, showExcluded: excluded)
    }
}

@MainActor final class TaskQueueSession: ObservableObject {
    @Published var filter = TaskHistoryQuery()
    var scope: TaskHistoryScope {
        get { filter.status }
        set { filter = .init(status: newValue) }
    }
    var taskType: TaskHistoryType {
        get { filter.type }
        set { filter = .init(type: newValue) }
    }
    @Published var totalCount = 0
    var query: TaskHistoryQuery { filter }

    func showAllTasks() {
        filter = .init()
    }
    @Published var rows: [TaskHistoryRow] = []
    @Published var selection: UUID?
    @Published var selectedRow: TaskHistoryRow?
    @Published var loadingPage = false
    @Published var hasOlder = true
    @Published var hasNewer = false
    @Published var generation = UUID()
    @Published var canRetry = false
    @Published var canRestart = false
    @Published var canOpen = false
    @Published var failureOffset = 0
    @Published var ignoresNextScopeChange = false
    var visibleFirst: UUID?
    var visibleLast: UUID?
    var handledFocusID: UUID?
    private(set) var handledFocusRequest: UUID?

    /// Reopening Tasks preserves the user's selection. Each explicit navigation
    /// request can still reveal the same task again after the user changes filters.
    func receiveFocusRequest(_ request: UUID?) {
        guard let request, request != handledFocusRequest else { return }
        handledFocusRequest = request
        handledFocusID = nil
    }
    @Published var revealID: UUID?
    @Published var revealToken = UUID()
    private(set) var firstDisplayCursor: ManagedTaskJournal.DisplayCursor?
    private(set) var lastDisplayCursor: ManagedTaskJournal.DisplayCursor?
    private var displayedCursors: [UUID: ManagedTaskJournal.DisplayCursor] = [:]
    let viewport = NativeListViewport()
    var pageLoadTask: Task<Void, Never>?
    private(set) var pendingFocusID: UUID?
    private var refreshAfterFocus = false

    func footerCount(total: Int, historyLoading: Bool, hasHistoryError: Bool) -> Int? {
        !hasOlder && !historyLoading && !hasHistoryError && !rows.isEmpty ? total : nil
    }

    func beginPageLoad() -> UUID {
        pageLoadTask?.cancel()
        pageLoadTask = nil
        pendingFocusID = nil
        refreshAfterFocus = false
        generation = UUID()
        loadingPage = true
        return generation
    }

    func beginFocusLoad(_ id: UUID) -> UUID {
        let token = beginPageLoad()
        pendingFocusID = id
        return token
    }

    func deferRefreshUntilFocusCompletes() -> Bool {
        guard pendingFocusID != nil else { return false }
        refreshAfterFocus = true
        return true
    }

    func finishFocusLoad(_ token: UUID) -> Bool {
        guard generation == token else { return false }
        let needsRefresh = refreshAfterFocus
        pendingFocusID = nil
        refreshAfterFocus = false
        finishPageLoad(token)
        return needsRefresh
    }

    func finishPageLoad(_ token: UUID) {
        guard generation == token else { return }
        loadingPage = false
        pageLoadTask = nil
    }

    func refreshWhenIdle(_ refresh: () -> Void) {
        guard !loadingPage else { return }
        refresh()
    }

    /// A target can transition while its neighbours load. Retry its new position
    /// once, then let the caller load an ordinary page without extending the wait.
    func loadStableReveal<Page>(
        target: TaskHistoryRow, token: UUID,
        currentTarget: @MainActor () -> TaskHistoryRow?,
        load: @MainActor (TaskHistoryRow) async -> Page
    ) async -> (target: TaskHistoryRow, page: Page)? {
        var requested = target
        for _ in 0..<2 {
            guard !Task.isCancelled, generation == token else { return nil }
            let page = await load(requested)
            guard !Task.isCancelled, generation == token, let current = currentTarget() else { return nil }
            if current.displayCursor == requested.displayCursor { return (current, page) }
            requested = current
        }
        return nil
    }

    func cancelPageLoad() {
        pageLoadTask?.cancel()
        pageLoadTask = nil
        pendingFocusID = nil
        refreshAfterFocus = false
        generation = UUID()
        loadingPage = false
    }

    func select(_ row: TaskHistoryRow?) {
        if selectedRow?.id != row?.id { failureOffset = 0 }
        if selection != row?.id { selection = row?.id }
        if selectedRow != row { selectedRow = row }
    }

    func resetPagePresentation() {
        rows = []
        selectedRow = nil
        totalCount = 0
        firstDisplayCursor = nil
        lastDisplayCursor = nil
        displayedCursors = [:]
    }

    /// Durable commands finish even when navigation changes. Only the original
    /// selection and filter may request a reveal after the command suspends.
    func performTaskAction(id: UUID, operation: @MainActor () async -> Void) async -> Bool? {
        let requestedQuery = query
        let token = beginFocusLoad(id)
        await operation()
        guard generation == token else { return nil }
        let reveal = !Task.isCancelled && selection == id && query == requestedQuery
        _ = finishFocusLoad(token)
        return Task.isCancelled ? nil : reveal
    }

    /// Payload publication can include a newer transition. Keep the committed page
    /// boundaries until a page query deliberately replaces or extends the window.
    func replacePageRows(
        _ page: [TaskHistoryRow], retainingCursors: Bool = false, replacingCursors: Set<UUID> = []
    ) {
        let previous = retainingCursors ? displayedCursors : [:]
        displayedCursors = Dictionary(
            uniqueKeysWithValues: page.map {
                ($0.id, replacingCursors.contains($0.id) ? $0.displayCursor : previous[$0.id] ?? $0.displayCursor)
            })
        firstDisplayCursor = page.first.flatMap { displayedCursors[$0.id] }
        lastDisplayCursor = page.last.flatMap { displayedCursors[$0.id] }
        if rows != page { rows = page }
    }

    /// A returned page owns the current positions of overlapping identities. Move
    /// those rows before trimming so a transitioned row survives at its new edge.
    static func mergePage(
        _ incoming: [TaskHistoryRow], into current: [TaskHistoryRow], newer: Bool, limit: Int = 150,
        visibleFirst: UUID? = nil, visibleLast: UUID? = nil
    ) -> [TaskHistoryRow]? {
        let incomingIDs = Set(incoming.map(\.id))
        let retained = current.filter { !incomingIDs.contains($0.id) }
        var result = newer ? incoming + retained : retained + incoming
        let overflow = max(0, result.count - max(0, limit))
        guard overflow > 0 else { return result }
        let trimmedIDs = Set((newer ? Array(result.suffix(overflow)) : Array(result.prefix(overflow))).map(\.id))
        guard visibleFirst.map(trimmedIDs.contains) != true, visibleLast.map(trimmedIDs.contains) != true else {
            return nil
        }
        if newer {
            result.removeLast(overflow)
        }
        else {
            result.removeFirst(overflow)
        }
        return result
    }

    func advanceDisplayCursor(_ cursor: ManagedTaskJournal.DisplayCursor?, newer: Bool) {
        guard let cursor else { return }
        if newer {
            firstDisplayCursor = cursor
        }
        else {
            lastDisplayCursor = cursor
        }
    }

    func hasMovedSinceDisplay(_ row: TaskHistoryRow) -> Bool {
        guard let cursor = displayedCursors[row.id] else { return false }
        return cursor != row.displayCursor
    }

    func applyPage(
        _ page: [TaskHistoryRow], token: UUID, preferredPosition: Int = 0,
        retainingSelection: TaskHistoryRow? = nil
    ) {
        guard generation == token else { return }
        replacePageRows(page)
        let retained =
            page.first { $0.id == selection }
            ?? retainingSelection.flatMap { $0.id == selection ? $0 : nil }
        let replacement = page.isEmpty ? nil : page[min(max(0, preferredPosition), page.count - 1)]
        select(retained ?? replacement)
    }
}

/// Sort failure identities before resolving only the visible page's source context.
struct TaskFailurePage: Sendable {
    static func prepare(failures: [String: String], offset: Int) async -> Self {
        let worker = Task.detached(priority: .userInitiated) { Self(failures: failures, offset: offset) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static let size = 20
    let count: Int
    let offset: Int
    let entries: [(key: String, value: String)]
    var hasPrevious: Bool { offset > 0 }
    var hasNext: Bool { offset + Self.size < count }

    init(failures: [String: String], offset: Int) {
        count = failures.count
        let lastPage = max(0, (count - 1) / Self.size) * Self.size
        self.offset = min(max(0, offset / Self.size) * Self.size, lastPage)
        entries = failures.keys.sorted().dropFirst(self.offset).prefix(Self.size).compactMap { key in
            failures[key].map { (key: key, value: $0) }
        }
    }

    func resolve<Value>(_ context: (String, String) -> Value) -> [Value] {
        entries.map { context($0.key, $0.value) }
    }
}
