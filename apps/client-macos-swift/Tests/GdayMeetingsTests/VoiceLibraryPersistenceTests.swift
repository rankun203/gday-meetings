import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct VoiceLibraryPersistenceTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func fixture() -> VoiceLibraryDocument {
        var value = VoiceLibraryDocument()
        let vector = TypedVoiceEmbedding(type: .community1, values: [1] + Array(repeating: 0, count: 255))
        value.examples = [
            VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system", embeddings: [vector]),
            VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system"),
        ]
        value.jobs = [
            VoicePreparationJob(
                providerID: UUID(), providerName: "Synthetic provider", type: .community1, discover: false,
                exampleIDs: value.examples.map(\.id))
        ]
        return value
    }

    @Test func migrationOutputDecodesWithProductionSwiftModels() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var input = fixture()
        input.examples[0].review = .confirmed
        input.examples[0].personID = UUID()
        input.examples[1].review = .rejected
        input.examples[1].rejectedPersonIDs = [UUID()]
        input.undo = [.init(examples: input.examples.map(VoiceExampleReviewSnapshot.init), decisions: [])]
        let bytes = try JSONEncoder().encode(input)
        try bytes.write(to: root.appendingPathComponent("voice-library.json"))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "uv", "run", "--no-project", repository.appendingPathComponent("scripts/migrate_voice_library.py").path,
            root.path, "--apply", "--app-stopped",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["UV_CACHE_DIR"] = root.appendingPathComponent("uv-cache").path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "Migration failed: \(message)")
        let backend = try VoiceLibraryPersistence(directory: root, writable: false)
        let loaded = try #require(try backend.load(includeRepresentations: true))
        #expect(Set(loaded.examples.map(\.id)) == Set(input.examples.map(\.id)))
        #expect(loaded.examples.contains(input.examples[0]))
        #expect(loaded.examples.contains(input.examples[1]))
        #expect(loaded.jobs == input.jobs && loaded.undo == input.undo)
        #expect(try Data(contentsOf: root.appendingPathComponent("voice-library.json.pre-sharded-backup")) == bytes)
    }

    @Test func jobProgressAndReviewLeaveVectorsAndUnrelatedRecordsUntouched() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        #expect(try backend.load() == nil)
        let original = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: original)
        let vectorURL = backend.directory.appendingPathComponent("representations/\(original.examples[0].id).json")
        let unrelatedURL = backend.directory.appendingPathComponent("examples/\(original.examples[1].id).json")
        let vectorBytes = try Data(contentsOf: vectorURL)
        let vectorRevision = VoiceLibraryStore.revision(url: vectorURL)
        let unrelatedRevision = VoiceLibraryStore.revision(url: unrelatedURL)
        var next = original
        next.jobs[0].state = .running
        try backend.commit(previous: original, next: next)
        let beforeReview = next
        next.examples[0].personID = UUID()
        next.examples[0].review = .confirmed
        try backend.commit(previous: beforeReview, next: next)
        #expect(try Data(contentsOf: vectorURL) == vectorBytes)
        #expect(VoiceLibraryStore.revision(url: vectorURL) == vectorRevision)
        #expect(VoiceLibraryStore.revision(url: unrelatedURL) == unrelatedRevision)
        let metadata = try #require(try backend.load())
        #expect(metadata.examples.allSatisfy { $0.embeddings.isEmpty })
        #expect(
            try backend.loadRepresentations(exampleID: original.examples[0].id)?.embeddings
                == original.examples[0].embeddings)
    }

    @Test func metadataOpenAndJobProgressDoNotDecodeVectorFiles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        _ = try backend.load()
        let initial = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: initial)
        let vectorURL = backend.directory.appendingPathComponent("representations/\(initial.examples[0].id).json")
        try Data("not a decoded representation".utf8).write(to: vectorURL)
        let reopened = try VoiceLibraryPersistence(directory: root)
        let metadata = try #require(try reopened.load())
        var updated = metadata
        updated.jobs[0].state = .paused
        try reopened.commit(previous: metadata, next: updated)
        #expect(try String(contentsOf: vectorURL, encoding: .utf8) == "not a decoded representation")
        #expect(throws: (any Error).self) { try reopened.loadRepresentations(exampleID: initial.examples[0].id) }
        let header = backend.directory.appendingPathComponent("state.json")
        let before = VoiceLibraryStore.revision(url: header)
        let readonly = try VoiceLibraryPersistence(directory: root, writable: false)
        #expect(try readonly.load()?.jobs.first?.state == .paused)
        #expect(VoiceLibraryStore.revision(url: header) == before)
    }

    @Test func committedRedoRecoversWithoutClaimingRollback() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(
            directory: root,
            write: { data, url in
                if url.deletingLastPathComponent().lastPathComponent == "jobs" {
                    throw ServiceError("Synthetic materialization failure")
                }
                try data.write(to: url, options: .atomic)
            })
        _ = try backend.load()
        let expected = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: expected)
        #expect(backend.maintenanceWarning != nil)
        let readOnly = try VoiceLibraryPersistence(directory: root, writable: false)
        let overlay = try #require(try readOnly.load())
        #expect(overlay.jobs == expected.jobs)
        #expect(
            FileManager.default.fileExists(atPath: backend.directory.appendingPathComponent("transaction.json").path))
        let recovered = try VoiceLibraryPersistence(directory: root)
        #expect(try recovered.load(includeRepresentations: true)?.examples.contains(expected.examples[0]) == true)
        #expect(
            !FileManager.default.fileExists(atPath: backend.directory.appendingPathComponent("transaction.json").path))
    }

    @Test func publishedMarkerIsCommittedEvenIfWriterThrowsAfterPublication() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(
            directory: root,
            write: { data, url in
                try data.write(to: url, options: .atomic)
                if url.lastPathComponent == "transaction.json" {
                    throw ServiceError("Synthetic error after publication")
                }
            })
        _ = try backend.load()
        let expected = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: expected)
        #expect(try backend.load()?.jobs == expected.jobs)
    }

    @Test func failedExternalRollbackCannotAdoptUncommittedRevision() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        _ = try backend.load()
        let initial = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: initial)
        var next = initial
        next.examples[0].excluded = true
        var transaction = LibraryFileTransaction(root: root)
        try backend.commit(previous: initial, next: next, transaction: &transaction)
        #expect(throws: (any Error).self) { try backend.reloadRevision(committed: false) }
        try transaction.restore()
    }

    @Test func staleWriterAndExternalRecordEditAreRejected() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try VoiceLibraryPersistence(directory: root)
        let second = try VoiceLibraryPersistence(directory: root)
        _ = try first.load()
        _ = try second.load()
        let initial = fixture()
        try first.commit(previous: VoiceLibraryDocument(), next: initial)
        #expect(throws: (any Error).self) { try second.commit(previous: VoiceLibraryDocument(), next: initial) }
        let loaded = try #require(try second.load())
        var edited = loaded.examples[0]
        edited.excluded = true
        let url = second.directory.appendingPathComponent("examples/\(edited.id).json")
        try JSONEncoder().encode(edited).write(to: url, options: .atomic)
        var next = loaded
        next.examples[0].manuallyCleared = true
        #expect(throws: (any Error).self) { try second.commit(previous: loaded, next: next) }
    }

    @Test func externalMeetingTransactionRollsBackShardsAndRevision() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try VoiceLibraryPersistence(directory: root)
        _ = try backend.load()
        let initial = fixture()
        try backend.commit(previous: VoiceLibraryDocument(), next: initial)
        var next = initial
        next.examples[0].personID = UUID()
        var transaction = LibraryFileTransaction(root: root)
        try backend.commit(previous: initial, next: next, transaction: &transaction)
        try transaction.restore()
        try backend.reloadRevision(committed: false)
        #expect(try backend.load(includeRepresentations: true)?.examples.contains(initial.examples[0]) == true)
        try backend.commit(previous: initial, next: next)
    }

    @Test func legacyAndFutureFormatsAreNotRewritten() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("voice-library.json")
        let bytes = try JSONEncoder().encode(fixture())
        try bytes.write(to: legacy)
        #expect(throws: (any Error).self) { try VoiceLibraryPersistence(directory: root) }
        #expect(try Data(contentsOf: legacy) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-library").path))
    }
}
