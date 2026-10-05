import Combine
import Foundation

/// A bounded cursor window; the native table preserves its visible row when an edge rotates.
struct AssociatedMeetingWindow {
    static let limit = 200
    var page = AssociatedMeetingPage()

    mutating func merge(_ incoming: AssociatedMeetingPage, backwards: Bool) {
        let known = Set(page.entries.map(\.id))
        let additions = incoming.entries.filter { !known.contains($0.id) }
        page.total = incoming.total
        if backwards {
            page.entries.insert(contentsOf: additions, at: 0)
            page.hasNewer = incoming.hasNewer
            if page.entries.count > Self.limit {
                page.entries.removeLast(page.entries.count - Self.limit)
                page.hasOlder = true
            }
        }
        else {
            page.entries.append(contentsOf: additions)
            page.hasOlder = incoming.hasOlder
            if page.entries.count > Self.limit {
                page.entries.removeFirst(page.entries.count - Self.limit)
                page.hasNewer = true
            }
        }
    }
}

@MainActor final class AssociatedMeetingLoader: ObservableObject {
    @Published private(set) var window = AssociatedMeetingWindow()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var retryBackwards: Bool?

    func refresh(index: LibraryIndex?, personID: UUID?, tagID: UUID?) async {
        generation = UUID()
        let token = generation
        loading = true
        error = nil
        retryBackwards = nil
        guard let index else {
            loading = false
            return
        }
        let first = window.page.hasNewer ? window.page.entries.first : nil
        let limit = max(20, window.page.entries.count)
        defer { if token == generation { loading = false } }
        do {
            // Coalesce quick metadata updates without replacing the visible window.
            try await Task.sleep(for: .milliseconds(80))
            let page = try await Task.detached(priority: .userInitiated) {
                try AssociatedMeetingPage.around(
                    index: index, personID: personID, tagID: tagID, first: first, limit: limit)
            }.value
            guard token == generation, !Task.isCancelled else { return }
            window.page = page
        }
        catch is CancellationError {}
        catch {
            guard token == generation else { return }
            self.error = "Couldn’t refresh associated meetings. \(error.localizedDescription)"
        }
    }

    func observe(_ viewport: MeetingViewport, index: LibraryIndex?, personID: UUID?, tagID: UUID?) {
        guard !loading, error == nil, let index,
            let first = window.page.entries.firstIndex(where: { $0.id == viewport.firstID }),
            let last = window.page.entries.firstIndex(where: { $0.id == viewport.lastID })
        else { return }
        let previous = window.page.hasNewer && first < 12
        let next = window.page.hasOlder && window.page.entries.count - last < 12
        let backwards: Bool
        if previous && viewport.rowsPerSecond < -1 {
            backwards = true
        }
        else if next {
            backwards = false
        }
        else if previous {
            backwards = true
        }
        else {
            return
        }
        Task { await load(index: index, personID: personID, tagID: tagID, backwards: backwards) }
    }

    func retry(index: LibraryIndex?, personID: UUID?, tagID: UUID?) async {
        guard let index else { return }
        if let backwards = retryBackwards {
            await load(index: index, personID: personID, tagID: tagID, backwards: backwards)
        }
        else {
            await refresh(index: index, personID: personID, tagID: tagID)
        }
    }

    private func load(index: LibraryIndex, personID: UUID?, tagID: UUID?, backwards: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        retryBackwards = backwards
        let token = generation
        let edge = backwards ? window.page.entries.first : window.page.entries.last
        defer { if token == generation { loading = false } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AssociatedMeetingPage.read(
                    index: index, personID: personID, tagID: tagID,
                    after: backwards ? nil : edge, before: backwards ? edge : nil)
            }.value
            guard token == generation, !Task.isCancelled else { return }
            window.merge(result, backwards: backwards)
        }
        catch {
            guard token == generation else { return }
            self.error = "Couldn’t load associated meetings. \(error.localizedDescription)"
        }
    }
}

struct AssociatedMeetingPage {
    var entries: [MeetingListEntry] = []
    var total = 0
    var hasNewer = false
    var hasOlder = false

    static func read(
        index: LibraryIndex, personID: UUID?, tagID: UUID?, after: MeetingListEntry? = nil,
        before: MeetingListEntry? = nil, limit: Int = 20
    ) throws -> Self {
        let entries = try index.page(after: after, before: before, limit: limit, personID: personID, tagID: tagID)
        let total = try index.count(personID: personID, tagID: tagID)
        let newer =
            try entries.first.map { !(try index.page(before: $0, limit: 1, personID: personID, tagID: tagID)).isEmpty }
            ?? false
        let older =
            try entries.last.map { !(try index.page(after: $0, limit: 1, personID: personID, tagID: tagID)).isEmpty }
            ?? false
        return Self(entries: entries, total: total, hasNewer: newer, hasOlder: older)
    }
    static func around(index: LibraryIndex, personID: UUID?, tagID: UUID?, first: MeetingListEntry?, limit: Int) throws
        -> Self
    {
        let previous = try first.flatMap {
            try index.page(before: $0, limit: 1, personID: personID, tagID: tagID).last
        }
        return try read(index: index, personID: personID, tagID: tagID, after: previous, limit: limit)
    }

}
