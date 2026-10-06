import Foundation
import Testing
@testable import GdayMeetings

struct RealLibrarySearchValidationTests {
    @MainActor @Test func validateAuthorizedLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GDAY_SEARCH_VALIDATION_DATA_DIR"],
              let queryPath = environment["GDAY_SEARCH_VALIDATION_QUERIES"],
              let reportPath = environment["GDAY_SEARCH_VALIDATION_REPORT"] else { return }
        let directory = URL(fileURLWithPath: path)
        let library = try LibraryIndex(directory: directory)
        if library.requiresRebuild { try library.rebuild() }
        var entries: [MeetingListEntry] = []
        var cursor: MeetingListEntry?
        while true {
            let page = try library.page(after: cursor, limit: 100)
            if page.isEmpty { break }
            entries.append(contentsOf: page)
            cursor = page.last
        }
        let model = SemanticModelID.granite97M
        let manager = LocalModelManager(root: directory.appendingPathComponent("LocalModels"))
        let encoder = CoreMLSemanticEmbedding(modelID: model, manager: manager)
        let index = try SemanticSearchIndex(directory: directory, indexDirectory: directory)
        var configuration = LocalSearchConfiguration()
        configuration.semanticModel = model
        let provider = SemanticSearchProvider(id: UUID(), configuration: configuration, directory: directory, index: index, encoder: encoder)
        let started = Date()
        try await provider.prepare()
        var failures: [[String: String]] = []
        var completed = 0
        for entry in entries {
            do {
                try await provider.updateIndex(meetingID: entry.id, progress: { _ in })
                completed += 1
            } catch {
                failures.append(["meetingID":entry.id.uuidString, "error":error.localizedDescription])
            }
            if completed % 10 == 0 { print("Local search indexed \(completed)/\(entries.count) meetings") }
        }
        let indexingSeconds = Date().timeIntervalSince(started)
        let queries = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: queryPath)))
        var results: [[String: Any]] = []
        for query in queries {
            let began = Date()
            var rows: [[String: Any]] = []
            for try await snapshot in provider.search(.init(query: query, mode: .semantic, limit: 5)) {
                rows = snapshot.value.results.map { result in
                    ["meetingID":result.meetingID.uuidString, "title":result.title, "excerpt":result.excerpt,
                     "score":result.scoreBreakdown?.total ?? 0, "timestamp":result.passage?.start ?? -1]
                }
            }
            results.append(["query":query, "milliseconds":Date().timeIntervalSince(began)*1000, "results":rows])
            #expect(!rows.isEmpty)
        }
        let report: [String:Any] = ["model":model.rawValue,"space":model.space,"meetings":entries.count,
            "completed":completed,"failures":failures,"indexingSeconds":indexingSeconds,"queries":results]
        try JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:reportPath))
        await provider.unload()
        #expect(failures.isEmpty)
        print("Local search validation complete: \(completed) meetings, \(queries.count) queries, \(failures.count) failures")
    }
}
