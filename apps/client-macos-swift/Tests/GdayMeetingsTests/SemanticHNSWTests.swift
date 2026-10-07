import CSQLite
import Foundation
import Testing
import USearchC

@testable import GdayMeetings

struct SemanticHNSWTests {
    @Test func temporaryPathAliasesWorkAndEscapingCacheSymlinksAreRejected() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathExtension("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        try await index.prepare(model: .granite97M)
        await index.unload()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".index-search-graphs"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SemanticSearchIndex(directory: root, indexDirectory: root) }
    }
    private func vector(_ similarity: Double, dimensions: Int = 384) -> [Double] {
        var result = [Double](repeating: 0, count: dimensions)
        result[0] = similarity
        result[1] = sqrt(1 - similarity * similarity)
        return result
    }
    private func fixture(
        root: URL, title: String, count: Int, similarity: Double, tags: [UUID] = [], person: UUID? = nil
    ) throws -> (Meeting, SemanticMeetingArtifact, String) {
        var meeting = Meeting(title: title)
        meeting.tagIDs = tags
        try MeetingFolderStorage.write(meeting, directory: root)
        let fingerprint = try SemanticSource.fingerprint(
            folder: MeetingFolderLocation.resolve(id: meeting.id, directory: root))
        let windows = (0..<count).map { position in
            SemanticWindow(
                id: "window-\(position)", text: "Synthetic passage \(position)", kind: "transcript",
                start: Double(position), end: Double(position + 1), people: Set([person].compactMap { $0 }),
                vector: vector(similarity))
        }
        return (
            meeting,
            .init(
                space: SemanticModelID.granite97M.space, meetingID: meeting.id, revision: "fixture", windows: windows),
            fingerprint
        )
    }
    @Test func packedCoordinatesRoundTripAndRejectCorruption() throws {
        let artifact = SemanticMeetingArtifact(
            space: "fixture", meetingID: UUID(), revision: "one",
            windows: [
                .init(id: "one", text: "Synthetic", kind: "notes", people: [], vector: vector(0.76))
            ])
        let packed = try PackedSemanticArtifact(artifact)
        #expect(packed.fp32.count == 1536)
        #expect(packed.int8.count == 384)
        #expect(packed.metadata.windows[0].vector.isEmpty)
        let decoded = try packed.unpack()
        #expect(abs(decoded.windows[0].vector[0] - 0.76) < 0.000001)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(packed)
        var plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        plist["int8"] = Data(repeating: 0, count: 384)
        let corrupt = try PropertyListDecoder().decode(
            PackedSemanticArtifact.self,
            from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
        #expect(throws: (any Error).self) { try corrupt.unpack() }
    }
    @Test func checkpointsBatchMeetingsAndReplayCommittedChangesAfterCrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let first = try fixture(root: root, title: "First", count: 12, similarity: 0.8)
        let second = try fixture(root: root, title: "Second", count: 7, similarity: 0.9)
        let request = ProviderSearchRequest(query: "Synthetic", mode: .semantic, limit: 100)
        try await index.persist(first.1, fingerprint: first.2)
        try await index.persist(second.1, fingerprint: second.2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".index-search-graphs").path))
        // Crash before the first checkpoint reconstructs from committed packed rows.
        await index.discardGraph()
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 19)
        try await index.saveGraph(force: true)
        let third = try fixture(root: root, title: "Third", count: 5, similarity: 0.7)
        try await index.persist(third.1, fingerprint: third.2)
        try await index.remove(first.0.id)
        // Repeat the already-applied journal on the same graph: additions and removals are idempotent.
        try await index.repeatUncheckpointedJournal()
        await index.discardGraph()
        let reopened = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let results = try await reopened.search(vector: vector(1), model: .granite97M, request: request, boost: 0)
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0.meetingID != first.0.id })
        // Pruning after checkpoint must not strand an older connection's resident graph.
        try await reopened.saveGraph(force: true)
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 12)
        let storage = try IndexDatabase.open(at: root.appendingPathComponent("index.db"))
        let journal = try storage.prepare("SELECT count(*) FROM provider_semantic_journal")
        #expect(sqlite3_step(journal) == SQLITE_ROW)
        #expect(sqlite3_column_int(journal, 0) == 0)
        storage.release(journal)
    }
    @Test func modelSpacesKeepBothDimensionsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(root: root, title: "Two models", count: 2, similarity: 0.8)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        try await index.persist(item.1, fingerprint: item.2)
        var windows = item.1.windows
        for i in windows.indices { windows[i].vector = vector(0.9, dimensions: 768) }
        try await index.persist(
            .init(space: SemanticModelID.granite311M.space, meetingID: item.0.id, revision: "other", windows: windows),
            fingerprint: item.2)
        let request = ProviderSearchRequest(query: "Synthetic", mode: .semantic, limit: 100)
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 2)
        #expect(
            try await index.search(
                vector: vector(1, dimensions: 768), model: .granite311M,
                request: request, boost: 0
            ).count == 2)
        try await index.reset(space: SemanticModelID.granite97M.space)
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).isEmpty)
        #expect(
            try await index.search(
                vector: vector(1, dimensions: 768), model: .granite311M,
                request: request, boost: 0
            ).count == 2)
    }
    @Test func appendAndMetadataUpdatesOnlyJournalChangedVectors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(root: root, title: "Incremental", count: 2, similarity: 0.8)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        try await index.persist(item.1, fingerprint: item.2)
        let initial = try #require(await index.state(space: item.1.space)).sequence
        var windows = item.1.windows
        windows.append(
            .init(id: "appended", text: "Synthetic addition", kind: "notes", people: [], vector: vector(0.9)))
        func artifact() -> SemanticMeetingArtifact {
            .init(space: item.1.space, meetingID: item.0.id, revision: "updated", windows: windows)
        }
        try await index.persist(artifact(), fingerprint: item.2)
        #expect(try await index.state(space: item.1.space)?.sequence == initial + 1)
        windows[0].people = [UUID()]
        try await index.persist(artifact(), fingerprint: item.2)
        #expect(try await index.state(space: item.1.space)?.sequence == initial + 1)
        windows[0].vector = vector(0.7)
        try await index.persist(artifact(), fingerprint: item.2)
        #expect(try await index.state(space: item.1.space)?.sequence == initial + 2)
        windows.removeLast()
        try await index.persist(artifact(), fingerprint: item.2)
        #expect(try await index.state(space: item.1.space)?.sequence == initial + 3)
        let results = try await index.search(
            vector: vector(1), model: .granite97M,
            request: .init(query: "Synthetic", mode: .semantic, limit: 100), boost: 0)
        #expect(results.count == 2)
    }
    @Test func speakerUnionAndTagPrefilterDoNotLoseCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let tag = UUID()
        let person = UUID()
        let hidden = try fixture(root: root, title: "Excluded", count: 1200, similarity: 0.99, tags: [tag])
        let content = try fixture(root: root, title: "Content", count: 1100, similarity: 0.8)
        let spoken = try fixture(root: root, title: "Speaker", count: 1, similarity: 0.76, person: person)
        for item in [hidden, content, spoken] {
            do { try await index.persist(item.1, fingerprint: item.2) }
            catch { throw ServiceError("Fixture persistence (\(item.0.title)): \(error)") }
        }
        let request = ProviderSearchRequest(
            query: "Synthetic", mode: .semantic, limit: 100, excludingTagIDs: [tag], identifiedPeople: [person])
        let results: [ProviderSearchResult]
        do { results = try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0.1) }
        catch { throw ServiceError("Filtered speaker search: \(error)") }
        #expect(results.count == 100)
        #expect(results.first?.meetingID == spoken.0.id)
        #expect(results.allSatisfy { $0.meetingID != hidden.0.id })
        #expect(abs((results.first?.scoreBreakdown?.total ?? 0) - 0.86) < 0.000001)
        let stored = try PackedSemanticArtifact.read(
            folder: MeetingFolderLocation.resolve(id: spoken.0.id, directory: root),
            space: SemanticModelID.granite97M.space, meetingID: spoken.0.id)
        #expect(stored.windows.count == 1)
        let noBonus = try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0)
        #expect(noBonus.first?.meetingID == content.0.id)
    }
    @Test func replacementDeletionExternalConnectionAndCorruptSnapshotRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(root: root, title: "Original", count: 32, similarity: 0.8)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        try await index.persist(item.1, fingerprint: item.2)
        let storage = try IndexDatabase.open(at: root.appendingPathComponent("index.db"))
        let sizes = try storage.prepare(
            "SELECT count(*),sum(length(fp32)),sum(length(int8)),min(typeof(fp32)),min(typeof(int8)) FROM provider_semantic_windows"
        )
        #expect(sqlite3_step(sizes) == SQLITE_ROW)
        #expect(sqlite3_column_int(sizes, 0) == 32)
        #expect(sqlite3_column_int(sizes, 1) == 32 * 1536)
        #expect(sqlite3_column_int(sizes, 2) == 32 * 384)
        #expect(String(cString: sqlite3_column_text(sizes, 3)) == "blob")
        #expect(String(cString: sqlite3_column_text(sizes, 4)) == "blob")
        storage.release(sizes)
        let observer = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let request = ProviderSearchRequest(query: "Synthetic", mode: .semantic, limit: 100)
        #expect(
            try await observer.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 32)
        var windows = item.1.windows
        windows.removeLast(22)
        let replacement = SemanticMeetingArtifact(
            space: item.1.space, meetingID: item.0.id, revision: "two", windows: windows)
        try await index.persist(replacement, fingerprint: item.2)
        #expect(
            try await observer.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 10)
        await index.unload()
        await observer.unload()
        for file in try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(".index-search-graphs"), includingPropertiesForKeys: nil)
        where file.pathExtension == "usearch" {
            try Data("corrupt".utf8).write(to: file)
        }
        let recovered = try SemanticSearchIndex(directory: root, indexDirectory: root)
        #expect(
            try await recovered.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 10)
        let reopened = try SemanticSearchIndex(directory: root, indexDirectory: root)
        #expect(
            try await reopened.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 10)
        try await index.remove(item.0.id)
        #expect(try await reopened.search(vector: vector(1), model: .granite97M, request: request, boost: 0).isEmpty)
        try await index.persist(item.1, fingerprint: item.2)
        var changed = item.0
        changed.title = "Changed"
        try MeetingFolderStorage.write(changed, directory: root)
        #expect(try await reopened.search(vector: vector(1), model: .granite97M, request: request, boost: 0).isEmpty)
    }
    @Test func rebuildUsesPackedArtifactWithoutEncodingAndCancellationDoesNotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(root: root, title: "Rebuild", count: 5, similarity: 0.8)
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        try await index.persist(item.1, fingerprint: item.2)
        try await index.reset(space: item.1.space)
        let recovered = try PackedSemanticArtifact.read(
            folder: MeetingFolderLocation.resolve(id: item.0.id, directory: root), space: item.1.space,
            meetingID: item.0.id)
        try await index.persist(recovered, fingerprint: item.2)
        let request = ProviderSearchRequest(query: "Synthetic", mode: .semantic, limit: 100)
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 5)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await index.persist(item.1, fingerprint: item.2)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await index.search(vector: vector(1), model: .granite97M, request: request, boost: 0).count == 5)
    }
}

extension SemanticHNSWTests {
    /// Fresh-process resource check, without constructing fixtures or loading an embedding model.
    @Test func measureExistingPackedIndex() async throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_HNSW_EXISTING_INDEX_ROOT"],
            let vectors = ProcessInfo.processInfo.environment["GDAY_HNSW_BENCHMARK_VECTORS"]
        else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let baseline = await PerformanceResourceSnapshot.capture()
        let library = try LibraryIndex(directory: root)
        defer { withExtendedLifetime(library) {} }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let started = ContinuousClock.now
        try await index.prepare(model: .granite97M)
        let load = started.duration(to: .now)
        let loaded = await PerformanceResourceSnapshot.capture()
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: vectors))
        defer { try? file.close() }
        var times: [Double] = []
        for offset in 0..<12 {
            try file.seek(toOffset: UInt64(offset * 107 * 1536))
            let read = try file.read(upToCount: 1536)
            let data = try #require(read)
            let query = try PackedSemanticArtifact.vector(data, dimensions: 384).map(Double.init)
            let start = ContinuousClock.now
            let results = try await index.search(
                vector: query, model: .granite97M,
                request: .init(query: "Integration validation", mode: .semantic, limit: 100), boost: 0)
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(results.count == 100)
        }
        let queried = await PerformanceResourceSnapshot.capture()
        print(
            "HNSW_EXISTING load=\(load) baselineRSS=\(baseline.residentBytes ?? 0) loadedRSS=\(loaded.residentBytes ?? 0) queriedRSS=\(queried.residentBytes ?? 0) footprintBytes=\(queried.physicalFootprintBytes ?? 0) queryMs=\(times)"
        )
        await index.unload()
    }
    /// Opt-in integration measurement: private vectors, synthetic documents, ignored outputs only.
    @Test func measureFrozenVectorsThroughProductionPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_HNSW_BENCHMARK_VECTORS"] else { return }
        let baseline = await PerformanceResourceSnapshot.capture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        var queries: [[Double]] = []
        var total = 0
        let buildStart = ContinuousClock.now
        while let data = try file.read(upToCount: 107 * 384 * 4), !data.isEmpty {
            guard data.count.isMultiple(of: 1536) else { throw SearchProviderError.invalidResponse }
            let count = data.count / 1536
            let item = try fixture(root: root, title: "Synthetic benchmark", count: count, similarity: 0.8)
            var windows = item.1.windows
            for i in 0..<count {
                windows[i].vector = try PackedSemanticArtifact.vector(
                    data.subdata(in: i * 1536..<(i + 1) * 1536), dimensions: 384
                ).map(Double.init)
            }
            if queries.count < 12 { queries.append(windows[0].vector) }
            try await index.persist(
                .init(space: item.1.space, meetingID: item.0.id, revision: "benchmark", windows: windows),
                fingerprint: item.2)
            total += count
            if total >= 39066 { break }
        }
        let build = buildStart.duration(to: .now)
        await index.unload()
        let loadStart = ContinuousClock.now
        try await index.prepare(model: .granite97M)
        let load = loadStart.duration(to: .now)
        let hardware = await index.measuredHardware()
        #expect(hardware != "serial")
        var times: [Double] = []
        var graphTimes: [Double] = []
        for query in queries {
            let start = ContinuousClock.now
            let results = try await index.search(
                vector: query, model: .granite97M,
                request: .init(query: "Synthetic", mode: .semantic, limit: 100), boost: 0)
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(results.count == 100)
            #expect((results.first?.scoreBreakdown?.similarity ?? 0) > 0.999)
            graphTimes.append(try await index.measureCandidateSearch(query))
        }
        let resources = await PerformanceResourceSnapshot.capture()
        print("HNSW_INTEGRATION hardware=\(hardware) windows=\(total) build=\(build) load=\(load) queryMs=\(times)")
        print(
            "HNSW_RESOURCES baselineRSS=\(baseline.residentBytes ?? 0) residentBytes=\(resources.residentBytes ?? 0) footprintBytes=\(resources.physicalFootprintBytes ?? 0) graphMs=\(graphTimes)"
        )
    }
}

extension SemanticHNSWTests {
    /// Explicit opt-in after the stopped-app converter; emits aggregate measurements only.
    @Test func rebuildConvertedLibraryProjection() async throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_HNSW_CONVERTED_LIBRARY"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let library = try LibraryIndex(directory: root)
        defer { withExtendedLifetime(library) {} }
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let manager = await LocalModelManager(root: root.appendingPathComponent("LocalModels", isDirectory: true))
        let encoder = CoreMLSemanticEmbedding(modelID: .granite97M, manager: manager)
        let provider = SemanticSearchProvider(
            id: UUID(), configuration: .init(), directory: root, index: index, encoder: encoder)
        let folders = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("meetings"), includingPropertiesForKeys: nil)
        var meetings = 0
        var windows = 0
        var queries: [[Double]] = []
        let start = ContinuousClock.now
        for folder in folders {
            guard let id = MeetingFolderLocation.identity(folder.lastPathComponent) else { continue }
            // Production update verifies current content and associations before reusing embeddings.
            try await provider.updateIndex(meetingID: id) { _ in }
            let artifact = try PackedSemanticArtifact.read(
                folder: folder, space: SemanticModelID.granite97M.space, meetingID: id)
            meetings += 1
            windows += artifact.windows.count
            if queries.count < 12, let first = artifact.windows.first { queries.append(first.vector) }
        }
        let build = start.duration(to: .now)
        #expect(meetings > 0)
        await index.unload()
        let loadStart = ContinuousClock.now
        try await index.prepare(model: .granite97M)
        let load = loadStart.duration(to: .now)
        var times: [Double] = []
        for query in queries {
            let queryStart = ContinuousClock.now
            let results = try await index.search(
                vector: query, model: .granite97M,
                request: .init(query: "Integration validation", mode: .semantic, limit: 100), boost: 0)
            let elapsed = queryStart.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(results.count == 100)
            #expect((results.first?.scoreBreakdown?.similarity ?? 0) > 0.999)
        }
        print("HNSW_LIBRARY meetings=\(meetings) windows=\(windows) build=\(build) load=\(load) queryMs=\(times)")
        await provider.unload()
    }
    @Test func quantizationMatchesNativeCast() throws {
        var options = usearch_init_options_t(
            metric_kind: usearch_metric_cos_k, metric: nil,
            quantization: usearch_scalar_i8_k, dimensions: 384, connectivity: 32,
            expansion_add: 128, expansion_search: 2000, multi: false)
        var error: usearch_error_t?
        let graph = try #require(usearch_init(&options, &error))
        defer { usearch_free(graph, &error) }
        usearch_reserve(graph, 1, &error)
        let values = vector(0.76).map(Float.init)
        values.withUnsafeBufferPointer { usearch_add(graph, 1, $0.baseAddress, usearch_scalar_f32_k, &error) }
        #expect(error == nil)
        var actual = [Int8](repeating: 0, count: 384)
        _ = usearch_get(graph, 1, 1, &actual, usearch_scalar_i8_k, &error)
        #expect(error == nil)
        let packed = try PackedSemanticArtifact(
            .init(
                space: "fixture", meetingID: UUID(), revision: "one",
                windows: [
                    .init(id: "one", text: "Synthetic", kind: "notes", people: [], vector: vector(0.76))
                ]))
        #expect(actual.withUnsafeBytes { Data($0) } == packed.int8)
    }
    @Test func decodePythonMigrationFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_HNSW_PACKED_FIXTURE"] else { return }
        let packed = try PropertyListDecoder().decode(
            PackedSemanticArtifact.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let artifact = try packed.unpack()
        #expect(artifact.windows.count == 1)
        #expect(abs(artifact.windows[0].vector[0] - 0.8) < 0.000001)
    }
}

private extension SemanticSearchIndex {
    func measuredHardware() -> String { graph?.hardware ?? "unloaded" }
    func measureCandidateSearch(_ query: [Double]) throws -> Double {
        let start = ContinuousClock.now
        _ = try graph?.search(query.map(Float.init), count: 1000, excluding: [])
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    func repeatUncheckpointedJournal() throws {
        guard let graph, let space = graphSpace, let state = try state(space: space) else {
            throw SearchProviderError.invalidResponse
        }
        graphSequence = state.checkpoint
        try replay(graph, space: space, through: state.sequence)
    }
}
