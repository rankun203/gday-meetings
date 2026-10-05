import Foundation

/// The actor owns the reusable name index and bundled frequency dictionary.
/// Rebuilding and linguistic analysis never run in a SwiftUI body or on MainActor.
actor PeopleNameResolver {
    private var records: [PeopleNameRecord] = []
    private var index = PeopleNameIndex(people: [])
    private var frequentWords: Set<String>?
    private(set) var rebuildCount = 0

    func update(_ people: [PeopleNameRecord]) {
        guard people != records else { return }
        records = people
        index = PeopleNameIndex(people: people)
        rebuildCount += 1
    }
    func resolve(_ query: String, people: [PeopleNameRecord]) throws -> PeopleNameResolution {
        update(people)
        if people.isEmpty { return .empty(query) }
        try Task.checkCancellation()
        if frequentWords == nil { frequentWords = try Self.loadFrequentWords() }
        return index.resolve(query, frequentWords: frequentWords ?? [])
    }
    private static func loadFrequentWords() throws -> Set<String> {
        struct Dictionary: Decodable { let words: [String: [String]] }
        guard let url = Bundle.module.url(forResource: "frequent-words", withExtension: "json") else {
            throw ServiceError("The People name dictionary is missing. Reinstall the app to restore it.")
        }
        return Set(try JSONDecoder().decode(Dictionary.self, from: Data(contentsOf: url)).words.values.flatMap { $0 })
    }
}
