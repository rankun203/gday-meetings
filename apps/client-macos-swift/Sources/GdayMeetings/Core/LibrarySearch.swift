import Combine
import Foundation

/// Indexed source locations let search open content without starting playback.
enum LibrarySearchKind: String, Sendable { case title, notes, summary, transcript }

struct LibrarySearchPassage: Sendable {
    var kind: LibrarySearchKind
    var segmentID: UUID? = nil
    var start: Double? = nil
    var text: String
}

struct LibrarySearchResult: Identifiable, Equatable, Sendable {
    let id: Int64
    let meetingID: UUID
    let title: String
    let createdAt: Date
    let kind: LibrarySearchKind
    let segmentID: UUID?
    let start: Double?
    let excerpt: String
}

struct LibrarySearchPage: Sendable {
    let results: [LibrarySearchResult]
    let total: Int
}

extension MeetingFolderStorage {
    static func searchPassages(id: UUID, directory: URL) throws -> [LibrarySearchPassage] {
        let folder = try MeetingFolderLocation.resolve(id: id, directory: directory)
        var passages: [LibrarySearchPassage] = []
        for (name, kind) in [("notes.md", LibrarySearchKind.notes), ("summary.md", .summary)] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                passages.append(
                    LibrarySearchPassage(
                        kind: kind,
                        text: NotesReadingDocument(try String(contentsOf: file, encoding: .utf8)).searchableText))
            }
        }
        passages += try TranscriptStorage.read(at: folder).map {
            LibrarySearchPassage(kind: .transcript, segmentID: $0.id, start: $0.start, text: $0.text)
        }
        return passages
    }
}

/// Reuse the production block and inline parsers before FTS chooses an excerpt.
/// This keeps timing metadata, link destinations, and image paths out of snippets.
extension NotesReadingDocument {
    var searchableText: String {
        func inline(_ source: String) -> String {
            let text = NSMutableString(string: source)
            for image in NotesImageReference.parse(in: source).reversed() {
                text.replaceCharacters(in: image.range, with: image.alt)
            }
            return MarkdownSelectionSourceMap(source: text as String).rendered
        }
        return blocks.compactMap { block -> String? in
            switch block.content {
            case .text(let text), .literal(let text), .heading(let text, _), .list(let text, _), .quote(let text):
                return inline(text)
            case .code(let text): return text
            case .image(let image): return image.alt
            case .table(let rows, _): return rows.map { $0.map(inline).joined(separator: " ") }.joined(separator: "\n")
            case .divider: return nil
            }
        }.joined(separator: "\n")
    }
}

@MainActor
final class LibrarySearchSession: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [LibrarySearchResult] = []
    @Published private(set) var total: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    var selection: Int64?
    var scrollOffset: Double = 0
    private(set) var generation = UUID()
    private var task: Task<Void, Never>?
    private var index: LibraryIndex?
    private var exhausted = false
    private var excludingTagIDs: Set<UUID> = []
    private let loadPage: @Sendable (LibraryIndex, String, Int64, Set<UUID>) async throws -> LibrarySearchPage

    init(
        loadPage: @escaping @Sendable (LibraryIndex, String, Int64, Set<UUID>) async throws -> LibrarySearchPage = {
            index, query, cursor, excludingTagIDs in
            try await Task.detached(priority: .userInitiated) {
                try index.searchPage(query: query, after: cursor, excludingTagIDs: excludingTagIDs)
            }.value
        }
    ) {
        self.loadPage = loadPage
    }
    var canLoadMore: Bool { !isLoading && error == nil && !exhausted }

    @discardableResult
    func submit(_ draft: String, index: LibraryIndex?, excludingTagIDs: Set<UUID> = []) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        task?.cancel()
        generation = UUID()
        self.index = index
        self.excludingTagIDs = excludingTagIDs
        query = trimmed
        results = []
        total = nil
        exhausted = false
        error = nil
        selection = nil
        scrollOffset = 0
        load()
        return true
    }

    func retry() { load() }
    func loadMore() { if canLoadMore { load() } }

    private func load() {
        guard let index else {
            error = "The library index is unavailable. Try again after the library finishes loading."
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        let generation = generation
        let query = query
        let cursor = results.last?.id ?? 0
        let excludingTagIDs = excludingTagIDs
        task = Task {
            do {
                let page = try await loadPage(index, query, cursor, excludingTagIDs)
                guard !Task.isCancelled, generation == self.generation else { return }
                results += page.results
                total = page.total
                exhausted = page.results.count < 50
                isLoading = false
            }
            catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                self.error = "Couldn’t search the library. \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
