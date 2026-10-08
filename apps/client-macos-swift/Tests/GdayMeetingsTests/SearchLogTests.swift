import Foundation
import Testing

@testable import GdayMeetings

struct SearchLogTests {
    private func events(_ log: SearchLog) throws -> [SearchLogEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: log.fileURL).split(separator: 10).map {
            try decoder.decode(SearchLogEvent.self, from: Data($0))
        }
    }

    @Test func concurrentAppendsPreserveEventsAndEscapedQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = SearchLog(directory: root, providerID: UUID())
        let request = ProviderSearchRequest(query: "Synthetic\nquery \"example\" 中文")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { log.record(.init(kind: "search_started", requestID: request.id, request: request)) }
            }
        }
        await SearchLog.flush()
        let initial = try Data(contentsOf: log.fileURL)
        log.record(.init(kind: "search_failed", requestID: request.id, error: "Synthetic failure"))
        await SearchLog.flush()
        let saved = try events(log)
        #expect(saved.count == 101)
        #expect(Set(saved.map(\.eventID)).count == 101)
        #expect(saved.allSatisfy { $0.providerID == log.providerID && $0.schemaVersion == 1 })
        #expect(saved.first?.request?.query == request.query)
        #expect(try Data(contentsOf: log.fileURL).starts(with: initial))
        #expect(log.fileURL.path.hasSuffix("providers/\(log.providerID.uuidString)/search-log.jsonl"))
    }

    @Test func partialTailDoesNotConsumeNextEventAndSymlinksAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = SearchLog(directory: root, providerID: UUID())
        let event = SearchLogEvent(kind: "search_started", requestID: UUID())
        try log.append(event)
        let file = try FileHandle(forWritingTo: log.fileURL)
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"torn\":".utf8))
        try file.close()
        try log.append(event)
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1] == "{\"torn\":")
        #expect(lines[2].contains("search_started"))
        let linked = SearchLog(directory: root, providerID: UUID())
        try FileManager.default.createSymbolicLink(
            at: linked.fileURL.deletingLastPathComponent(), withDestinationURL: root)
        #expect(throws: (any Error).self) { try linked.append(event) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("search-log.jsonl").path))
    }

    @Test @MainActor func displayedSnapshotAndClicksStayLinkedAcrossNewQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(directory: root)
        let log = SearchLog(directory: root, providerID: LocalTextSearchProvider.id)
        let meetingID = UUID()
        let session = LibrarySearchSession(loadPage: { _, _, _, _ in
            .init(
                results: [
                    .init(
                        id: 1, meetingID: meetingID, title: "Synthetic meeting", createdAt: Date(), kind: .notes,
                        segmentID: nil, start: nil, excerpt: "First match"),
                    .init(
                        id: 2, meetingID: meetingID, title: "Synthetic meeting", createdAt: Date(), kind: .notes,
                        segmentID: nil, start: nil, excerpt: "Second match"),
                ], total: 2)
        })
        #expect(session.submit("Synthetic", index: index))
        for _ in 0..<200 where session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let result = try #require(session.displayResults.last)
        session.recordInteraction(result, action: "open", input: "mouse")
        session.beginPreparation("Next", mode: .semantic, log: log)
        session.recordInteraction(result, action: "open", input: "mouse")
        session.preparationFailed("Synthetic model unavailable")
        await SearchLog.flush()
        let saved = try events(log)
        let display = try #require(saved.first { $0.kind == "results_displayed" })
        let clicks = saved.filter { $0.kind == "result_interaction" }
        #expect(clicks.count == 1)
        #expect(clicks.first?.snapshotID == display.snapshotID)
        #expect(clicks.first?.requestID == display.requestID)
        #expect(clicks.first?.interaction?.groupRank == 1)
        #expect(clicks.first?.interaction?.resultRank == 2)
        #expect(clicks.first?.interaction?.matchRank == 2)
        #expect(saved.last?.kind == "preparation_failed")
    }
}

private actor SearchLogFailureEncoder: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID = .granite97M
    let waits: Bool
    private(set) var entered = false
    init(waits: Bool) { self.waits = waits }
    func prepare() {}
    func unload() {}
    func passageParts(_ text: String) -> [String] { [text] }
    func embed(_ text: String, isQuery: Bool) async throws -> [Double] {
        entered = true
        if waits { try await Task.sleep(for: .seconds(30)) }
        throw SearchProviderError.invalidResponse
    }
}

extension SearchLogTests {
    @Test func failuresAndCancellationHaveTerminalEventsWithoutResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        for cancelled in [false, true] {
            let encoder = SearchLogFailureEncoder(waits: cancelled)
            let provider = SemanticSearchProvider(
                id: UUID(), configuration: .init(), directory: root, index: index, encoder: encoder)
            let request = ProviderSearchRequest(query: "Synthetic query", mode: .semantic)
            let task = Task {
                do { for try await _ in provider.search(request) {} }
                catch {}
            }
            while !(await encoder.entered) { await Task.yield() }
            if cancelled { task.cancel() }
            await task.value
            let log = try #require(provider.searchLog)
            var saved: [SearchLogEvent] = []
            for _ in 0..<200 {
                await SearchLog.flush()
                saved = (try? events(log)) ?? []
                if saved.count == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(saved.map(\.kind) == ["search_started", cancelled ? "search_cancelled" : "search_failed"])
            #expect(saved.allSatisfy { $0.requestID == request.id && $0.snapshot == nil })
            #expect(saved.last?.timingsMS?["total"] != nil)
        }
    }
}
