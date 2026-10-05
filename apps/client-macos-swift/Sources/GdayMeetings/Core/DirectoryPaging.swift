import Combine
import Foundation

extension MeetingStore {
    func refreshDirectoryIndex(paths: [URL] = [], rebuild: Bool = false) {
        if directoryIndex == nil {
            do { directoryIndex = try DirectoryIndex(root: dataDirectory, indexDirectory: indexDirectory) }
            catch {
                directoryIndexError = error.localizedDescription
                return
            }
        }
        guard let index = directoryIndex else { return }
        index.enqueue(paths: paths, rebuild: rebuild) { [weak self, weak index] error in
            Task { @MainActor in
                guard let self, self.directoryIndex === index else { return }
                self.directoryIndexError = error
                self.directoryRevision = UUID()
            }
        }
    }

    /// Call only after authoritative writes commit, before replacing the save baseline.
    func refreshDirectoryIndex(previousPeople: [Person], previousTags: [MeetingTag]) {
        let oldPeople = Dictionary(uniqueKeysWithValues: previousPeople.map { ($0.id, $0) })
        let oldTags = Dictionary(uniqueKeysWithValues: previousTags.map { ($0.id, $0) })
        let peopleIDs = Set(people.filter { oldPeople[$0.id] != $0 }.map(\.id))
            .union(Set(oldPeople.keys).subtracting(people.map(\.id)))
        let tagIDs = Set(tags.filter { oldTags[$0.id] != $0 }.map(\.id))
            .union(Set(oldTags.keys).subtracting(tags.map(\.id)))
        let paths =
            peopleIDs.map { dataDirectory.appendingPathComponent("people/\($0.uuidString).json") }
            + tagIDs.map { dataDirectory.appendingPathComponent("tags/\($0.uuidString).json") }
        // Meeting-only changes still refresh indexed associated counts for visible pages.
        refreshDirectoryIndex(paths: paths)
    }
}

@MainActor final class DirectoryPaging: ObservableObject {
    static let pageSize = 50
    static let windowLimit = 400
    @Published private(set) var entries: [DirectoryEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var revealRequest: DirectoryReveal?
    private var pendingReveal: (id: UUID, query: String, expectedName: String?)?
    private var index: DirectoryIndex?
    private var kind: DirectoryKind = .people
    private var query = ""
    private var showExcluded = false
    private var hasPrevious = false
    private var hasNext = true
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func configure(index: DirectoryIndex?, kind: DirectoryKind, query: String, showExcluded: Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pendingReveal, pendingReveal.query != query { self.pendingReveal = nil }
        let same = self.index === index && self.kind == kind && self.query == query && self.showExcluded == showExcluded
        task?.cancel()
        generation = UUID()
        self.index = index
        self.kind = kind
        self.query = query
        self.showExcluded = showExcluded
        let anchor = same ? entries.first : nil
        if !same {
            entries = []
            total = 0
            hasPrevious = false
        }
        request(after: anchor, before: nil, replace: true, inclusive: same)
    }
    func reveal(_ id: UUID, query: String, expectedName: String? = nil) {
        pendingReveal = (id, query.trimmingCharacters(in: .whitespacesAndNewlines), expectedName)
        configure(index: index, kind: kind, query: query, showExcluded: showExcluded)
    }
    func retry() { configure(index: index, kind: kind, query: query, showExcluded: showExcluded) }
    func viewport(first: UUID, last: UUID) {
        guard !loading, error == nil, let firstIndex = entries.firstIndex(where: { $0.id == first }),
            let lastIndex = entries.firstIndex(where: { $0.id == last })
        else { return }
        if hasPrevious && firstIndex < 15 {
            request(after: nil, before: entries.first, replace: false)
        }
        else if hasNext && entries.count - lastIndex < 20 {
            request(after: entries.last, before: nil, replace: false)
        }
    }
    private func request(after: DirectoryEntry?, before: DirectoryEntry?, replace: Bool, inclusive: Bool = false) {
        guard let index else {
            error = "The directory index is unavailable. Rebuild it in Data settings."
            return
        }
        loading = true
        error = nil
        let generation = generation
        let kind = kind
        let query = query
        let showExcluded = showExcluded
        let revealTarget = pendingReveal?.id
        let expectedName = pendingReveal?.expectedName
        let limit = replace ? max(Self.pageSize, entries.count) : Self.pageSize
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    () throws -> (DirectoryPage, DirectoryWindow?) in
                    if let revealTarget,
                        let window = try index.window(
                            kind: kind, id: revealTarget, query: query, showExcluded: showExcluded,
                            expectedName: expectedName)
                    {
                        return (window.page, window)
                    }
                    let page = try index.page(
                        kind: kind, query: query, showExcluded: showExcluded, after: after, before: before,
                        limit: limit, includingCursor: inclusive)
                    if replace, let after, page.entries.isEmpty, page.total > 0 {
                        let previous = try index.page(
                            kind: kind, query: query, showExcluded: showExcluded, before: after, limit: limit)
                        return (previous, nil)
                    }
                    return (page, nil)
                }.value
                let page = result.0
                guard !Task.isCancelled, generation == self.generation else { return }
                total = page.total
                if let window = result.1, let revealTarget {
                    entries = page.entries
                    hasPrevious = window.hasPrevious
                    hasNext = window.hasNext
                    pendingReveal = nil
                    revealRequest = DirectoryReveal(targetID: revealTarget)
                }
                else if replace {
                    entries = page.entries
                    hasNext = page.entries.count == limit
                }
                else if before != nil {
                    entries.insert(contentsOf: page.entries, at: 0)
                    hasPrevious = page.entries.count == limit
                    if entries.count > Self.windowLimit {
                        entries.removeLast(entries.count - Self.windowLimit)
                        hasNext = true
                    }
                }
                else {
                    entries += page.entries
                    hasNext = page.entries.count == limit
                    if entries.count > Self.windowLimit {
                        entries.removeFirst(entries.count - Self.windowLimit)
                        hasPrevious = true
                    }
                }
                loading = false
                task = nil
            }
            catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                self.error = error.localizedDescription
                loading = false
                task = nil
            }
        }
    }
}
