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
    @Published var scope = TaskHistoryScope.all
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
    @Published var revealID: UUID?
    @Published var revealToken = UUID()
    let viewport = NativeListViewport()
    var pageLoadTask: Task<Void, Never>?
    private(set) var pendingFocusID: UUID?
    private var refreshAfterFocus = false

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
        selection = row?.id
        selectedRow = row
    }

    func resetPagePresentation() {
        rows = []
        selectedRow = nil
    }

    func applyPage(_ page: [TaskHistoryRow], token: UUID, preferredPosition: Int = 0) {
        guard generation == token else { return }
        rows = page
        let retained = page.first { $0.id == selection }
        let replacement = page.isEmpty ? nil : page[min(max(0, preferredPosition), page.count - 1)]
        select(retained ?? replacement)
    }
}

/// Sort failure identities before resolving only the visible page's source context.
struct TaskFailurePage {
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
