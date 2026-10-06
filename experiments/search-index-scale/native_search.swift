import CSQLite
import Darwin
import Foundation
import Testing

@testable import GdayMeetings

private struct NativeFixtureRow: Codable {
    let id: UUID
    let folder: String
    let artifact: String
    let byteOffset: Int
    let windows: Int
}

private func resources() -> [String: Double] {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    var info = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &info) {
        proc_pid_rusage(
            getpid(), RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
    }
    precondition(status == 0)
    return [
        "rss": Double(info.ri_resident_size), "peakRSS": Double(usage.ru_maxrss),
        "physicalFootprint": Double(info.ri_phys_footprint),
        "readBytes": Double(info.ri_diskio_bytesread), "writtenBytes": Double(info.ri_diskio_byteswritten),
        "cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
        "thermalState": Double(ProcessInfo.processInfo.thermalState.rawValue),
    ]
}

private func floats(_ data: Data) -> [Double] {
    stride(from: 0, to: data.count, by: 4).map { offset in
        data.withUnsafeBytes {
            Double(Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
        }
    }
}

private extension SemanticSearchIndex {
    func nativePooledSearch(vector: [Double], model: SemanticModelID, request: ProviderSearchRequest) throws
        -> [ProviderSearchResult]
    {
        try autoreleasepool { try search(vector: vector, model: model, request: request, boost: 0.1) }
    }
}

struct NativeSearchScaleTests {
    @Test func runNativeSearchMeasurement() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let basePath = env["GDAY_NATIVE_FIXTURE"], let mode = env["GDAY_NATIVE_MODE"],
            let scaleText = env["GDAY_NATIVE_SCALE"], let scale = Int(scaleText)
        else { return }
        let base = URL(fileURLWithPath: basePath).standardizedFileURL
        precondition(base.path.contains("/experiments/search-index-scale/runs/native/"))
        let root = base.appendingPathComponent("library")
        let beforeOpen = resources()
        let openStart = ContinuousClock.now
        let library = try LibraryIndex(directory: root)
        let catalogOpened = ContinuousClock.now
        let index = try SemanticSearchIndex(directory: root, indexDirectory: root)
        let semanticOpened = ContinuousClock.now
        // Keep the production folder-index registration alive throughout every search.
        defer { withExtendedLifetime(library) {} }
        let afterOpen = resources()
        let model = SemanticModelID.granite97M
        if mode == "prepare" {
            let rows = try JSONDecoder().decode(
                [NativeFixtureRow].self,
                from: Data(contentsOf: base.appendingPathComponent("block-\(scale).json")))
            let vectorPath = try String(contentsOf: base.appendingPathComponent("vector-path.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let vectors = try FileHandle(forReadingFrom: URL(fileURLWithPath: vectorPath))
            defer { try? vectors.close() }
            let connection = try IndexDatabase.open(at: root.appendingPathComponent("index.db"))
            var metadataBytes = 0
            var vectorBytes = 0
            for row in rows {
                let folder = root.appendingPathComponent("meetings/" + row.folder)
                let fingerprint = try SemanticSource.fingerprint(folder: folder)
                let original = try JSONDecoder().decode(
                    SemanticMeetingArtifact.self,
                    from: Data(contentsOf: base.appendingPathComponent(row.artifact)))
                let artifact = SemanticMeetingArtifact(
                    space: model.space, meetingID: row.id,
                    revision: original.revision, windows: original.windows)
                let data = try JSONEncoder().encode(artifact)
                metadataBytes += data.count
                try vectors.seek(toOffset: UInt64(row.byteOffset))
                let bytes = try vectors.read(upToCount: row.windows * 384 * 4)!
                #expect(bytes.count == row.windows * 384 * 4)
                vectorBytes += bytes.count
                try connection.write(module: SemanticSearchIndex.module) {
                    let sql = try connection.prepare("INSERT INTO provider_semantic_meetings VALUES(?,?,?,?,?,384)")
                    defer { connection.release(sql) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    for (offset, value) in [model.space, row.id.uuidString, fingerprint].enumerated() {
                        sqlite3_bind_text(sql, Int32(offset + 1), value, -1, transient)
                    }
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(sql, 4, $0.baseAddress, Int32(data.count), transient) }
                    _ = bytes.withUnsafeBytes {
                        sqlite3_bind_blob(sql, 5, $0.baseAddress, Int32(bytes.count), transient)
                    }
                    #expect(sqlite3_step(sql) == SQLITE_DONE)
                    let location = try connection.prepare("INSERT INTO meeting_folders VALUES(?,?)")
                    defer { connection.release(location) }
                    sqlite3_bind_text(location, 1, row.id.uuidString, -1, transient)
                    sqlite3_bind_text(location, 2, row.folder, -1, transient)
                    #expect(sqlite3_step(location) == SQLITE_DONE)
                }
            }
            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try report(
                [
                    "scale": scale, "meetingsAdded": rows.count, "metadataBytesAdded": metadataBytes,
                    "vectorBytesAdded": vectorBytes,
                ], base: base, name: "prepare-\(scale)")
            return
        }
        if mode == "mutation" {
            try await mutations(index: index, library: library, root: root, base: base, scale: scale)
            return
        }
        #expect(mode == "search")
        let queryBytes = try Data(contentsOf: base.appendingPathComponent("queries.f32"))
        let queries = stride(from: 0, to: queryBytes.count, by: 384 * 4).map {
            floats(queryBytes.subdata(in: $0..<($0 + 384 * 4)))
        }
        let indices = try JSONDecoder().decode(
            [Int].self, from: Data(contentsOf: base.appendingPathComponent("query-indices.json")))
        let limit = Int(env["GDAY_NATIVE_LIMIT"] ?? "5")!
        let queryCount = Int(env["GDAY_NATIVE_QUERY_COUNT"] ?? "11")!
        let idleMilliseconds = Int(env["GDAY_NATIVE_IDLE_MS"] ?? "0")!
        let separateTasks = env["GDAY_NATIVE_SEPARATE_TASKS"] == "1"
        let pooled = env["GDAY_NATIVE_AUTORELEASE_POOL"] == "1"
        let reportSuffix = env["GDAY_NATIVE_REPORT_SUFFIX"] ?? ""
        var samples: [[String: Any]] = []
        for (position, query) in queries.prefix(queryCount).enumerated() {
            let before = resources()
            let began = ContinuousClock.now
            let request = ProviderSearchRequest(query: "Synthetic benchmark query", mode: .semantic, limit: limit)
            let results: [ProviderSearchResult]
            if separateTasks {
                results = try await Task.detached {
                    try await index.search(vector: query, model: model, request: request, boost: 0.1)
                }.value
            }
            else if pooled {
                results = try await index.nativePooledSearch(vector: query, model: model, request: request)
            }
            else {
                results = try await index.search(vector: query, model: model, request: request, boost: 0.1)
            }
            let elapsed = milliseconds(began.duration(to: .now))
            let after = resources()
            #expect(results.count == limit)
            samples.append([
                "queryIndex": indices[position], "milliseconds": elapsed,
                "before": before, "after": after,
                "ids": results.map(\.id), "scores": results.map { $0.scoreBreakdown!.total },
            ])
            if idleMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(idleMilliseconds))
                samples[samples.count - 1]["afterIdle"] = resources()
            }
        }
        try report(
            [
                "scale": scale, "windows": scale * 39_066, "limit": limit,
                "sqliteVersion": String(cString: sqlite3_libversion()), "modelsLoaded": false,
                "queryLifecycle": pooled
                    ? "explicit-autorelease-pool" : separateTasks ? "separate-tasks" : "continuous-task",
                "idleMilliseconds": idleMilliseconds,
                "catalogOpenMilliseconds": milliseconds(openStart.duration(to: catalogOpened)),
                "indexOpenMilliseconds": milliseconds(catalogOpened.duration(to: semanticOpened)),
                "beforeOpen": beforeOpen, "afterOpen": afterOpen, "final": resources(), "queries": samples,
            ],
            base: base, name: "search-\(scale)-top\(limit)" + reportSuffix)
    }

    private func mutations(index: SemanticSearchIndex, library: LibraryIndex, root: URL, base: URL, scale: Int)
        async throws
    {
        let vectorPath = try String(contentsOf: base.appendingPathComponent("append-path.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let values = floats(try Data(contentsOf: URL(fileURLWithPath: vectorPath)))
        #expect(values.count == 1000 * 384)
        let person = UUID(uuidString: "00000000-0000-4000-9000-000000000001")!
        var artifacts: [(SemanticMeetingArtifact, String)] = []
        let model = SemanticModelID.granite97M
        for number in 0..<10 {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", number + 100))!
            var meeting = Meeting(title: "Synthetic mutation meeting \(number)")
            meeting.id = id
            let entry = MeetingListEntry(meeting)
            let folder = root.appendingPathComponent(
                "meetings/" + MeetingFolderLocation.name(id: id, date: entry.createdAt))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("metadata.json"))
            try library.upsert(entry, folder: folder, confirmedUnique: true, refreshSearch: false)
            let fingerprint = try SemanticSource.fingerprint(folder: folder)
            let windows = (0..<100).map { position in
                let offset = (number * 100 + position) * 384
                return SemanticWindow(
                    id: "mutation-\(position)", text: String(repeating: "Synthetic passage. ", count: 32),
                    kind: "transcript", start: Double(position), end: Double(position + 1), people: [person],
                    vector: Array(values[offset..<(offset + 384)]))
            }
            artifacts.append(
                (
                    .init(space: model.space, meetingID: id, revision: "synthetic-mutation", windows: windows),
                    fingerprint
                ))
        }
        var metrics: [String: Any] = [
            "scale": scale, "vectors": 1000, "meetings": 10,
            "transactionScope": "10 production meeting transactions; includes reusable provider JSON artifacts",
        ]
        let before = resources()
        let began = ContinuousClock.now
        for (artifact, fingerprint) in artifacts { try await index.persist(artifact, fingerprint: fingerprint) }
        metrics["append"] = [
            "milliseconds": milliseconds(began.duration(to: .now)), "before": before, "after": resources(),
        ]
        let inserted = Set(artifacts.map { $0.0.meetingID })
        for (artifact, fingerprint) in artifacts {
            #expect(try await index.isCurrent(artifact.meetingID, space: model.space, fingerprint: fingerprint))
        }
        let query = Array(values.prefix(384))
        let boosted = try await index.search(
            vector: query, model: model,
            request: .init(query: "Synthetic speaker query", mode: .semantic, limit: 5, identifiedPeople: [person]),
            boost: 0.2)
        #expect(boosted.count == 5)
        #expect(boosted.allSatisfy { inserted.contains($0.meetingID) && ($0.scoreBreakdown?.bonus ?? 0) == 0.2 })
        metrics["speakerBoostBeforeTopKPassed"] = true
        let deletionBefore = resources()
        let deletionStart = ContinuousClock.now
        for id in inserted.sorted(by: { $0.uuidString < $1.uuidString }) { try await index.remove(id) }
        metrics["delete"] = [
            "milliseconds": milliseconds(deletionStart.duration(to: .now)), "before": deletionBefore,
            "after": resources(),
        ]
        let reopened = try SemanticSearchIndex(directory: root, indexDirectory: root)
        for (artifact, fingerprint) in artifacts {
            #expect(try await !reopened.isCurrent(artifact.meetingID, space: model.space, fingerprint: fingerprint))
        }
        let afterDeletion = try await reopened.search(
            vector: query, model: model,
            request: .init(query: "Synthetic deletion query", mode: .semantic, limit: 100), boost: 0.1)
        #expect(afterDeletion.allSatisfy { !inserted.contains($0.meetingID) })
        metrics["deletedResultsAbsentAfterReopen"] = true
        try report(metrics, base: base, name: "mutation-\(scale)")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private func report(_ value: [String: Any], base: URL, name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: base.appendingPathComponent(name + ".json"))
        print("Native search measurement completed: \(name)")
    }
}
