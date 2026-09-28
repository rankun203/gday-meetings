import Foundation

struct MeetingViewport {
    var firstID: UUID
    var lastID: UUID
    var visibleCount: Int
    var rowsPerSecond: Double
}

@MainActor final class MeetingPrefetchState {
    var task: Task<Void, Never>?
    var generation = UUID()
    var viewport: MeetingViewport?
    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        viewport = nil
    }
}

extension MeetingStore {
    static let meetingWindowLimit = 800

    /// Read ahead from real viewport movement, never from synthetic list rows.
    func prefetchMeetings(_ viewport: MeetingViewport) {
        meetingPrefetch.viewport = viewport
        guard meetingPrefetch.task == nil, !isLoadingMeetingPage, meetingPageError == nil,
            let first = meetingCatalog.firstIndex(where: { $0.id == viewport.firstID }),
            let last = meetingCatalog.firstIndex(where: { $0.id == viewport.lastID }),
            let index = libraryIndex
        else { return }
        let lookAhead = max(40, min(240, viewport.visibleCount * 3 + Int(abs(viewport.rowsPerSecond) * 0.8)))
        let nextDistance = meetingCatalog.count - last - 1
        let wantsPrevious = meetingPageHasPrevious && first < lookAhead
        let wantsNext = meetingPageHasMore && nextDistance < lookAhead
        let backwards: Bool
        if viewport.rowsPerSecond < -1, wantsPrevious {
            backwards = true
        }
        else if wantsNext {
            backwards = false
        }
        else if wantsPrevious {
            backwards = true
        }
        else {
            return
        }
        let distance = backwards ? first : nextDistance
        let pageCount = min(10, max(2, (lookAhead - distance + 39) / Self.meetingPageSize))
        let edge = backwards ? meetingCatalog.first : meetingCatalog.last
        let query = meetingSearch
        let excludedTags = excludedTagIDs
        let generation = meetingPrefetch.generation
        let pageSize = Self.meetingPageSize
        isLoadingMeetingPage = true
        meetingPrefetch.task = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) { () throws -> ([MeetingListEntry], Bool) in
                var fetched: [MeetingListEntry] = []
                var cursor = edge
                var hasMore = true
                for _ in 0..<pageCount {
                    try Task.checkCancellation()
                    let page = try index.page(
                        after: backwards ? nil : cursor, before: backwards ? cursor : nil,
                        limit: pageSize, query: query, excludingTagIDs: excludedTags)
                    if backwards {
                        fetched.insert(contentsOf: page, at: 0)
                        cursor = page.first
                    }
                    else {
                        fetched.append(contentsOf: page)
                        cursor = page.last
                    }
                    if page.count < pageSize {
                        hasMore = false
                        break
                    }
                }
                if hasMore {
                    hasMore =
                        !(try index.page(
                            after: backwards ? nil : cursor, before: backwards ? cursor : nil,
                            limit: 1, query: query, excludingTagIDs: excludedTags)).isEmpty
                }
                return (fetched, hasMore)
            }
            do {
                let (fetched, hasMore) = try await withTaskCancellationHandler {
                    try await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard let self, !Task.isCancelled, self.meetingPrefetch.generation == generation else { return }
                let currentEdge = backwards ? self.meetingCatalog.first : self.meetingCatalog.last
                if currentEdge?.id == edge?.id && currentEdge?.createdAt == edge?.createdAt {
                    if backwards {
                        self.meetingCatalog.insert(contentsOf: fetched, at: 0)
                        self.meetingPageHasPrevious = hasMore
                    }
                    else {
                        self.meetingCatalog.append(contentsOf: fetched)
                        self.meetingPageHasMore = hasMore
                    }
                    self.trimMeetingWindow(backwards: backwards)
                    self.visibleMeetingIDs = self.meetingCatalog.map(\.id)
                }
                self.isLoadingMeetingPage = false
                self.meetingPrefetch.task = nil
                if let latest = self.meetingPrefetch.viewport { self.prefetchMeetings(latest) }
            }
            catch {
                guard let self, self.meetingPrefetch.generation == generation else { return }
                self.isLoadingMeetingPage = false
                self.meetingPrefetch.task = nil
                if !Task.isCancelled { self.meetingPageError = error.localizedDescription }
            }
        }
    }

    private func trimMeetingWindow(backwards: Bool) {
        let excess = meetingCatalog.count - Self.meetingWindowLimit
        guard excess > 0, let viewport = meetingPrefetch.viewport else { return }
        if backwards {
            let last = meetingCatalog.firstIndex { $0.id == viewport.lastID } ?? 0
            let removable = max(0, meetingCatalog.count - last - 41)
            let count = min(excess, removable)
            if count > 0 {
                meetingCatalog.removeLast(count)
                meetingPageHasMore = true
            }
        }
        else {
            let first = meetingCatalog.firstIndex { $0.id == viewport.firstID } ?? meetingCatalog.count
            let count = min(excess, max(0, first - 40))
            if count > 0 {
                meetingCatalog.removeFirst(count)
                meetingPageHasPrevious = true
            }
        }
    }
}
