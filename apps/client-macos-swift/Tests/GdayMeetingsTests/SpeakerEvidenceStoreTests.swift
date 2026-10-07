import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerEvidenceStoreTests {
    private func sample(_ index: Int) -> SpeakerEvidenceSample {
        SpeakerEvidenceSample(
            id: "example-\(index)", source: "microphone", localSpeakerID: "local-a",
            start: Double(index * 5), end: Double(index * 5 + 3),
            embedding: .init(type: .community1, values: [1] + [Double](repeating: 0, count: 255)))
    }

    @Test func retainsEveryEmbeddingAndActivityBeyondReviewLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerEvidenceStore(directory: root)
        for index in 0..<20 { try await store.append(sample(index)) }
        let activity = SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "local-a", start: 0, end: 100)
        try await store.append([activity])
        try await store.appendGap(source: "microphone", start: 100, end: 101, reason: "Synthetic input gap.")
        #expect(try !SpeakerEvidenceStore.isComplete(directory: root))
        try await store.finish()
        #expect(try SpeakerEvidenceStore.isComplete(directory: root))
        let document = try SpeakerEvidenceStore.read(directory: root)
        #expect(document.samples == (0..<20).map(sample))
        #expect(document.activity == [activity])
        await #expect(throws: (any Error).self) { try await store.append(sample(21)) }
        #expect(try SpeakerEvidenceStore.isComplete(directory: root))
    }

    @Test func privatePermissionsRejectFileAndDirectoryLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerEvidenceStore(directory: root)
        try await store.append(sample(0))
        try await store.finish()
        let url = root.appendingPathComponent(SpeakerEvidenceStore.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let original = try Data(contentsOf: url)
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: root)
        let linkedStore = SpeakerEvidenceStore(directory: linkedDirectory)
        await #expect(throws: (any Error).self) { try await linkedStore.append(sample(1)) }
        #expect(throws: (any Error).self) { try SpeakerEvidenceStore.read(directory: linkedDirectory) }
        let target = root.appendingPathComponent("untouched.jsonl")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let fileLinkStore = SpeakerEvidenceStore(directory: root)
        await #expect(throws: (any Error).self) { try await fileLinkStore.append(sample(1)) }
        #expect(throws: (any Error).self) { try SpeakerEvidenceStore.isComplete(directory: root) }
        #expect(try Data(contentsOf: target) == original)
        #expect(throws: (any Error).self) {
            try PrivateTranscriptFile.write(Data("replacement".utf8), name: SpeakerEvidenceStore.fileName, at: root)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func rejectsOversizedRecordsBeforeDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = Data(repeating: 0x20, count: 4 * 1024 * 1024)
        bytes.append(0x0A)
        try bytes.write(to: root.appendingPathComponent(SpeakerEvidenceStore.fileName))
        #expect(throws: (any Error).self) { try SpeakerEvidenceStore.read(directory: root) }
    }

    @Test func recoversTornTailAndRejectsCommittedCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerEvidenceStore(directory: root)
        try await store.append(sample(0))
        try await store.finish()
        let url = root.appendingPathComponent(SpeakerEvidenceStore.fileName)
        var bytes = try Data(contentsOf: url)
        bytes.append(contentsOf: "{\"version\":1".utf8)
        try bytes.write(to: url)
        #expect(try SpeakerEvidenceStore.read(directory: root).samples.count == 1)
        #expect(try !SpeakerEvidenceStore.isComplete(directory: root))
        let resumed = SpeakerEvidenceStore(directory: root)
        try await resumed.append(sample(1))
        try await resumed.finish(complete: false)
        #expect(try !SpeakerEvidenceStore.isComplete(directory: root))
        #expect(try SpeakerEvidenceStore.read(directory: root).samples == [sample(0), sample(1)])
        var corrupt = try Data(contentsOf: url)
        corrupt.append(contentsOf: "bad committed record\n".utf8)
        try corrupt.write(to: url)
        let blocked = SpeakerEvidenceStore(directory: root)
        await #expect(throws: (any Error).self) { try await blocked.append(sample(2)) }
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
