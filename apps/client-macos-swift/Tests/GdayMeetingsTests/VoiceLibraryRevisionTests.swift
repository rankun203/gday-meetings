import Foundation
import Testing

@testable import GdayMeetings

struct VoiceLibraryRevisionTests {
    @Test func targetedMetadataPreservesStoredRevisionFormatAndObservesExternalEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("voice.json")
        for index in 0..<32 {
            try Data(repeating: UInt8(index), count: index + 1).write(to: file, options: .atomic)
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 0.123456789)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let legacy = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = try #require(legacy[.size] as? NSNumber)
            let modified = try #require(legacy[.modificationDate] as? Date)
            #expect(VoiceLibraryStore.revision(url: file) == "\(size):\(modified.timeIntervalSince1970)")
        }
        let before = try #require(VoiceLibraryStore.revision(url: file))
        try Data("external replacement".utf8).write(to: file, options: .atomic)
        #expect(VoiceLibraryStore.revision(url: file) != before)
        #expect(VoiceLibraryStore.revision(url: root) == nil)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(VoiceLibraryStore.revision(url: link) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(VoiceLibraryStore.revision(url: file) == nil)
    }
    @Test func preparedMetadataMoveComparesPersistedVectorsWithoutRewritingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        let type = EmbeddingType(
            modelID: "fixture", revision: "1", compatibilityVersion: "1",
            dimension: 2, normalization: "unitL2")
        let example = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "microphone",
            audioFile: "microphone.wav", start: 0, end: 3,
            embeddings: [.init(type: type, values: [1, 0])])
        var original = VoiceLibraryDocument()
        original.examples = [example]
        try backend.commit(previous: .init(), next: original)
        let metadata = try #require(try backend.load())
        #expect(metadata.examples[0].embeddings.isEmpty)
        let file = root.appendingPathComponent("voice-library/representations/\(example.id.uuidString).json")
        let priorRevision = try #require(VoiceLibraryStore.revision(url: file))
        var next = metadata
        next.examples[0].groupID = UUID()
        next.examples[0].embeddings = example.embeddings
        try backend.commit(try backend.prepare(previous: metadata, next: next))
        #expect(VoiceLibraryStore.revision(url: file) == priorRevision)
        let saved = try #require(try backend.load(includeRepresentations: true))
        #expect(saved.examples[0].groupID == next.examples[0].groupID)
        #expect(saved.examples[0].embeddings == example.embeddings)
    }

}
