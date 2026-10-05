import Foundation
import Testing

@testable import GdayMeetings

struct PeopleNamePerformanceTests {
    @Test func boundedCatalogAndLongQueryWorkload() {
        func suffix(_ index: Int) -> String {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
            return String([alphabet[index / 26 % 26], alphabet[index % 26]])
        }
        let people = (0..<500).map { PeopleNameRecord(id: UUID(), name: "Ferna\(suffix($0)) Valen\(suffix($0))") }
        let started = ContinuousClock.now
        let index = PeopleNameIndex(people: people)
        let built = started.duration(to: .now)
        let query = people[240].name + " release plan"
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = index.resolve(query, frequentWords: [], detectNames: { _ in [] })
            times.append(start.duration(to: .now))
            #expect(result.confident.first?.personID == people[240].id)
        }
        let longQuery = Array(repeating: "quarterly delivery planning context", count: 40).joined(separator: " ")
        let start = ContinuousClock.now
        let result = index.resolve(longQuery, frequentWords: [], detectNames: { _ in [] })
        #expect(result.confident.isEmpty)
        #expect(result.residualQuery == longQuery)
        print(
            "People matcher adversarial workload: 500 names; build=\(built); queries=\(times); 160-word query=\(start.duration(to: .now))"
        )
    }
    @Test func variedCatalogResolverWorkload() async throws {
        let given = [
            "Zora", "Mira", "Ferna", "Lena", "Daria", "Nolan", "Oren", "Tessa", "Kira", "Petra",
            "Ronan", "Alina", "Celia", "Dorian", "Emrys", "Flora", "Galen", "Hana", "Iona", "Jasper",
        ]
        let family = [
            "Vale", "Bramble", "Cedar", "Dawson", "Ellery", "Finch", "Grove", "Hawthorn", "Irving", "Juniper",
            "Kestrel", "Larkin", "Marlow", "North", "Oakley", "Perrin", "Quill", "Reed", "Sable", "Thorne",
            "Underwood", "Voss", "Wren", "Yarrow", "Zephyr",
        ]
        let people = given.flatMap { first in family.map { PeopleNameRecord(id: UUID(), name: first + " " + $0) } }
        let resolver = PeopleNameResolver()
        let start = ContinuousClock.now
        let cold = try await resolver.resolve("Zora Vale release plan", people: people)
        let coldTime = start.duration(to: .now)
        #expect(cold.confident.contains { $0.personID == people[0].id })
        let warmStart = ContinuousClock.now
        _ = try await resolver.resolve("Mira Cedar delivery planning", people: people)
        let warmTime = warmStart.duration(to: .now)
        print("People matcher varied workload: 500 names; dictionary/native NLP cold=\(coldTime); warm=\(warmTime)")
    }

}
