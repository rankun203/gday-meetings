import Foundation
import Testing

@testable import GdayMeetings

struct RuntimeObservationsTests {
    @Test func observationsPersistAndKeepModelKeysIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = try RuntimeObservations(indexDirectory: root)
        let missing = try await observations.value(for: "search.prepare.seconds.synthetic-a")
        #expect(missing == nil)
        try await observations.record(2.5, for: "search.prepare.seconds.synthetic-a")
        try await observations.record(7, for: "search.prepare.seconds.synthetic-b")
        try await observations.record(3, for: "search.prepare.seconds.synthetic-a")
        try await observations.record(.nan, for: "search.prepare.seconds.synthetic-a")
        try await observations.record(-1, for: "search.prepare.seconds.synthetic-a")
        let reopened = try RuntimeObservations(indexDirectory: root)
        let first = try await reopened.value(for: "search.prepare.seconds.synthetic-a")
        let second = try await reopened.value(for: "search.prepare.seconds.synthetic-b")
        #expect(first == 3)
        #expect(second == 7)
    }
}
