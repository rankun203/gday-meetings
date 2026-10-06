import Foundation

/// The actor owns the reusable People name index.
/// Rebuilding and linguistic analysis never run in a SwiftUI body or on MainActor.
actor PeopleNameResolver {
    private var records: [PeopleNameRecord] = []
    private var index = PeopleNameIndex(people: [])
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
        return index.resolve(query)
    }
}
