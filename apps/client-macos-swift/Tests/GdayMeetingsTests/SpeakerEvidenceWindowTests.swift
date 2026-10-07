import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerEvidenceWindowTests {
    private func window(
        _ generation: String = "first", source: String = "microphone", start: Double = 0,
        end: Double = 10, capacity: Double? = nil
    ) -> SpeakerEvidenceWindow {
        .init(
            generation: generation, source: source, localSpeakerIDs: [generation + "-local"],
            publicationStart: start, observedEnd: end, capacityReachedAt: capacity,
            policyRevision: SpeakerEvidenceWindow.protectedPolicy)
    }

    @Test func capacityCutIsExactAndSaturatedBootstrapProvidesNoTrustedTime() throws {
        #expect(window(end: 25, capacity: 20).trustedEnd == 20)
        #expect(window(start: 45, end: 60, capacity: 30).trustedEnd == 45)
        var unknown = window()
        unknown.policyRevision = "unrecognized-policy"
        #expect(unknown.trustedEnd == nil)
        let legacy = try JSONDecoder().decode(
            SpeakerEvidenceDocument.self, from: Data("{\"samples\":[],\"activity\":[]}".utf8))
        #expect(legacy.windows == nil)
    }

    @Test func rejectsRegressingBoundsAndContradictoryCapacityWithoutLosingPriorEvidence() throws {
        var document = SpeakerEvidenceDocument()
        try document.recordWindow(window(end: 10))
        #expect(throws: (any Error).self) { try document.recordWindow(window(end: 9)) }
        #expect(throws: (any Error).self) { try document.recordWindow(window(end: 12, capacity: 8)) }
        try document.recordWindow(window(end: 15, capacity: 12))
        #expect(throws: (any Error).self) { try document.recordWindow(window(end: 16)) }
        #expect(throws: (any Error).self) { try document.recordWindow(window(end: 16, capacity: 13)) }
        #expect(document.windows?.first?.trustedEnd == 12)
    }

    @Test func nextGenerationsAndSourcesRemainIndependent() throws {
        var document = SpeakerEvidenceDocument()
        try document.recordWindow(window(end: 15, capacity: 12))
        try document.recordWindow(window("next", start: 15, end: 20))
        try document.recordWindow(window(source: "system", end: 20))
        #expect(document.windows?.count == 3)
        #expect(document.windows?.first { $0.generation == "next" }?.trustedEnd == 20)
        #expect(document.windows?.first { $0.source == "system" }?.trustedEnd == 20)
        #expect(throws: (any Error).self) { try document.recordWindow(window("overlap", start: 14, end: 17)) }
        var reused = window("different", start: 21, end: 25)
        reused.localSpeakerIDs = ["first-local"]
        #expect(throws: (any Error).self) { try document.recordWindow(reused) }
    }

    @Test func journalAggregatesWindowUpdatesWithActivityAndKeepsLegacyUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SpeakerEvidenceStore(directory: root)
        try await journal.append([], window: window(end: 0))
        try await journal.append(
            [.init(source: "microphone", localSpeakerID: "first-local", start: 0, end: 10)], window: window())
        try await journal.append([], window: window(end: 15, capacity: 12))
        try await journal.finish()
        let saved = try SpeakerEvidenceStore.read(directory: root)
        #expect(saved.windows?.count == 1)
        #expect(saved.windows?.first?.observedEnd == 15)
        #expect(saved.windows?.first?.trustedEnd == 12)
        #expect(saved.activity.count == 1)
    }

    @Test func journalRejectsWindowActivitySourceMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SpeakerEvidenceStore(directory: root)
        try await journal.append(
            [.init(source: "system", localSpeakerID: "first-local", start: 0, end: 10)], window: window())
        try await journal.finish()
        #expect(throws: (any Error).self) { try SpeakerEvidenceStore.read(directory: root) }
    }
}
