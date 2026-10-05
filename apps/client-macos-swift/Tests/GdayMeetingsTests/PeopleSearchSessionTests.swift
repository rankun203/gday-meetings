import Foundation
import Testing

@testable import GdayMeetings

private actor TopicRequests {
    var values: [String] = []
    func record(_ query: String) { values.append(query) }
}

@MainActor struct PeopleSearchSessionTests {
    @Test func confidentNamesUseResidualTopicAndNameOnlyDoesNotQueryContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = TopicRequests()
        let index = try LibraryIndex(directory: root)
        let session = LibrarySearchSession(loadPage: { _, query, _, _ in
            await requests.record(query)
            return .init(results: [], total: 0)
        })
        let person = PeopleNameRecord(id: UUID(), name: "Zora Vale")
        session.updatePeople([person])
        #expect(session.submit("Zora Vale budget", index: index))
        try #require(try await waitForMainActorTestCondition { !session.isLoading })
        #expect(session.query == "Zora Vale budget")
        #expect(session.contentQuery == "budget")
        #expect(await requests.values == ["budget"])
        #expect(session.submit("Zora Vale", index: nil))
        try #require(try await waitForMainActorTestCondition { !session.isLoading })
        #expect(session.peopleResolution.confident.first?.personID == person.id)
        #expect(session.contentQuery.isEmpty)
        #expect(session.error == nil)
        #expect(await requests.values == ["budget"])
    }
    @Test func renamingPeopleRefreshesExistingQueryWithoutStaleIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = TopicRequests()
        let index = try LibraryIndex(directory: root)
        let session = LibrarySearchSession(loadPage: { _, query, _, _ in
            await requests.record(query)
            return .init(results: [], total: 0)
        })
        let person = PeopleNameRecord(id: UUID(), name: "Zora Vale")
        session.updatePeople([person])
        #expect(session.submit("Zora Vale budget", index: index))
        try #require(try await waitForMainActorTestCondition { !session.isLoading })
        session.updatePeople([])
        try #require(try await waitForMainActorTestCondition { !session.isLoading })
        #expect(session.peopleResolution.candidates.isEmpty)
        #expect(session.contentQuery == "Zora Vale budget")
        #expect(await requests.values.last == "Zora Vale budget")
    }
}

private actor PeopleResolutionGate {
    var pending: [String: CheckedContinuation<PeopleNameResolution, Never>] = [:]
    func resolve(_ query: String, people: [PeopleNameRecord]) async -> PeopleNameResolution {
        await withCheckedContinuation { pending[people[0].name] = $0 }
    }
    func started(_ name: String) -> Bool { pending[name] != nil }
    func finish(_ name: String, result: PeopleNameResolution) {
        pending.removeValue(forKey: name)?.resume(returning: result)
    }
}

extension PeopleSearchSessionTests {
    @Test func providerPreparationWaitsForLatestPeopleRevision() async throws {
        let gate = PeopleResolutionGate()
        let session = LibrarySearchSession(resolvePeople: { await gate.resolve($0, people: $1) })
        let old = PeopleNameRecord(id: UUID(), name: "Earlier Person")
        let new = PeopleNameRecord(id: UUID(), name: "Current Person")
        session.updatePeople([old])
        session.beginPreparation("budget", mode: .voice)
        while await !gate.started(old.name) { await Task.yield() }
        var finished = false
        let waiter = Task {
            await session.waitForPeopleResolution()
            finished = true
        }
        session.updatePeople([new])
        while await !gate.started(new.name) { await Task.yield() }
        await gate.finish(old.name, result: .init(query: "budget", candidates: [], residualQuery: ""))
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished)
        #expect(session.contentQuery == "budget")
        await gate.finish(new.name, result: .empty("budget"))
        await waiter.value
        #expect(finished)
        #expect(session.contentQuery == "budget")
    }
}

extension PeopleSearchSessionTests {
    @Test func providerRefreshCanUpdatePeopleWithoutStartingLocalSearch() async throws {
        let session = LibrarySearchSession()
        let person = PeopleNameRecord(id: UUID(), name: "Zora Vale")
        session.updatePeople([person])
        session.beginPreparation("Zora Vale", mode: .voice)
        await session.waitForPeopleResolution()
        #expect(session.contentQuery.isEmpty)
        session.finishPeopleOnly()
        session.updatePeople([], refreshSearch: false)
        #expect(session.error == nil)
        #expect(session.contentQuery.isEmpty)
        session.beginPreparation(session.query, mode: .voice)
        await session.waitForPeopleResolution()
        #expect(session.contentQuery == "Zora Vale")
        #expect(session.error == nil)
        #expect(session.isLoading)
    }
}
