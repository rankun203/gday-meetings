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
    @Published var selectedFailures: [String] = []
    @Published var ignoresNextScopeChange = false
    var visibleFirst: UUID?
    var visibleLast: UUID?
    var handledFocusID: UUID?
    @Published var revealID: UUID?
    @Published var revealToken = UUID()
    let viewport = NativeListViewport()
}
