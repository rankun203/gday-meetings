import CSQLite
import CryptoKit
import Foundation

extension SemanticSearchIndex {
    struct GraphState {
        let epoch: String
        let dimensions: Int
        let sequence: Int64
        let checkpoint: Int64
    }
    struct GraphReceipt: Codable {
        let format: Int
        let epoch: String
        let dimensions: Int
        let count: Int
        let sequence: Int64
        let digest: String
    }
    func state(space: String) throws -> GraphState? {
        let statement = try connection.prepare(
            "SELECT epoch,dimensions,sequence,checkpoint FROM provider_semantic_state WHERE space=?")
        defer { connection.release(statement) }
        bind(space, 1, statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw connection.failure() }
        let epoch = text(statement, 0)
        guard UUID(uuidString: epoch) != nil else { throw SearchProviderError.invalidResponse }
        return .init(
            epoch: epoch, dimensions: Int(sqlite3_column_int(statement, 1)),
            sequence: sqlite3_column_int64(statement, 2), checkpoint: sqlite3_column_int64(statement, 3))
    }
    func journal(space: String, key: Int64, vector: Data?) throws {
        let statement = try connection.prepare("INSERT INTO provider_semantic_journal(space,key,int8) VALUES(?,?,?)")
        defer { connection.release(statement) }
        bind(space, 1, statement)
        sqlite3_bind_int64(statement, 2, key)
        if let vector {
            bind(vector, 3, statement)
        }
        else {
            sqlite3_bind_null(statement, 3)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
    }
    func advanceSequence(space: String) throws {
        try execute(
            "UPDATE provider_semantic_state SET sequence=max(sequence,coalesce((SELECT max(sequence) FROM provider_semantic_journal WHERE space=?),0)) WHERE space=?",
            strings: [space, space])
    }
    func refreshGraph(space: String, dimensions: Int) throws {
        try connection.execute("BEGIN")
        do {
            _ = try ensureGraph(space: space, dimensions: dimensions)
            try connection.execute("COMMIT")
        }
        catch {
            try? connection.execute("ROLLBACK")
            discardGraph()
            throw error
        }
    }
    // Called inside a read transaction so the snapshot, journal, and rows share one SQLite view.
    func ensureGraph(space: String, dimensions: Int) throws -> SemanticHNSWGraph {
        let state = try state(space: space)
        guard state == nil || state?.dimensions == dimensions else { throw SearchProviderError.invalidResponse }
        if graphSpace == space, graphEpoch == state?.epoch, let graph,
            graphSequence >= (state?.checkpoint ?? 0), graphSequence <= (state?.sequence ?? 0)
        {
            try replay(graph, space: space, through: state?.sequence ?? 0)
            return graph
        }
        discardGraph()
        var ready = try SemanticHNSWGraph(dimensions: dimensions)
        var loaded = false
        if let state, state.checkpoint > 0 {
            let url = snapshotURL(space: space, epoch: state.epoch, sequence: state.checkpoint)
            if let receipt = try? JSONDecoder().decode(
                GraphReceipt.self, from: Data(contentsOf: url.appendingPathExtension("json"))),
                receipt.format == 1, receipt.epoch == state.epoch, receipt.dimensions == dimensions,
                receipt.sequence == state.checkpoint, (try? Self.digest(url)) == receipt.digest
            {
                do {
                    try ready.load(url, expectedCount: receipt.count)
                    graphSequence = receipt.sequence
                    loaded = true
                }
                catch {
                    // Discard partial native state before rebuilding a corrupt cache.
                }
            }
        }
        if !loaded {
            ready = try SemanticHNSWGraph(dimensions: dimensions)
            let count = Int(
                try keys(
                    "SELECT count(*) FROM provider_semantic_windows WHERE space=?", strings: [space]
                ).first ?? 0)
            try ready.reserve(count)
            let statement = try connection.prepare(
                "SELECT key,int8 FROM provider_semantic_windows WHERE space=? ORDER BY key")
            defer { connection.release(statement) }
            bind(space, 1, statement)
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw connection.failure() }
                try ready.add(key: sqlite3_column_int64(statement, 0), bytes: blob(statement, 1))
            }
            graphSequence = state?.sequence ?? 0
            changesSinceCheckpoint = count
        }
        self.graph = ready
        graphSpace = space
        graphEpoch = state?.epoch
        graphNeedsSave = !loaded && graphSequence > 0
        lastCheckpoint = .now
        try replay(ready, space: space, through: state?.sequence ?? 0)
        return ready
    }
    func replay(_ graph: SemanticHNSWGraph, space: String, through sequence: Int64) throws {
        guard sequence > graphSequence else { return }
        let statement = try connection.prepare(
            "SELECT sequence,key,int8 FROM provider_semantic_journal WHERE space=? AND sequence>? AND sequence<=? ORDER BY sequence"
        )
        defer { connection.release(statement) }
        bind(space, 1, statement)
        sqlite3_bind_int64(statement, 2, graphSequence)
        sqlite3_bind_int64(statement, 3, sequence)
        do {
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw connection.failure() }
                let key = sqlite3_column_int64(statement, 1)
                // Removal of an absent key is harmless; replacing before adding makes replay idempotent.
                try graph.remove(key: key)
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    try graph.add(key: key, bytes: blob(statement, 2))
                }
                graphSequence = sqlite3_column_int64(statement, 0)
                changesSinceCheckpoint += 1
            }
            guard graphSequence == sequence else { throw SearchProviderError.invalidResponse }
            graphNeedsSave = true
        }
        catch {
            discardGraph()
            throw error
        }
    }
    func snapshotURL(space: String, epoch: String, sequence: Int64) -> URL {
        cacheDirectory.appendingPathComponent(
            SemanticSource.hash(Data(space.utf8)) + "-" + epoch + "-" + String(sequence) + ".usearch")
    }
    static func digest(_ url: URL) throws -> String {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw SearchProviderError.invalidResponse
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let consumed = try autoreleasepool {
                guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !consumed { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func saveGraph(force: Bool = false) throws {
        guard let graph, let space = graphSpace, let epoch = graphEpoch, graphNeedsSave else { return }
        // Bound full-graph serialization across meetings, including the final idle batch.
        if !force, changesSinceCheckpoint < 10_000, lastCheckpoint.duration(to: .now) < .seconds(30) {
            if checkpointTask == nil {
                checkpointTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    await self?.idleCheckpoint()
                }
            }
            return
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let sequence = graphSequence
        let url = snapshotURL(space: space, epoch: epoch, sequence: sequence)
        let temporary = cacheDirectory.appendingPathComponent(
            SemanticSource.hash(Data(space.utf8)) + "-" + epoch + "-" + UUID().uuidString + "-" + String(sequence)
                + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try graph.save(temporary)
        let receipt = GraphReceipt(
            format: 1, epoch: epoch, dimensions: graph.dimensions, count: graph.count,
            sequence: sequence, digest: try Self.digest(temporary))
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(receipt).write(to: url.appendingPathExtension("json"), options: .atomic)
        var published = false
        try connection.write(module: Self.module) {
            guard let current = try state(space: space), current.epoch == epoch,
                current.sequence >= sequence, current.checkpoint <= sequence
            else { return }
            try execute(
                "UPDATE provider_semantic_state SET checkpoint=? WHERE space=?",
                strings: [String(sequence), space])
            try execute(
                "DELETE FROM provider_semantic_journal WHERE space=? AND sequence<=?",
                strings: [space, String(sequence)])
            published = true
        }
        graphNeedsSave = false
        changesSinceCheckpoint = 0
        lastCheckpoint = .now
        checkpointTask?.cancel()
        checkpointTask = nil
        // Old snapshots are harmless. Remove them only while holding the SQLite writer lock,
        // so a different process cannot publish a newer checkpoint during cleanup.
        if published {
            try connection.write(module: Self.module) {
                guard let current = try state(space: space), current.epoch == epoch,
                    current.checkpoint == sequence
                else { return }
                try removeSnapshots(space: space, keeping: url.lastPathComponent, olderThan: sequence)
            }
        }
    }
    func idleCheckpoint() {
        checkpointTask = nil
        // Failure leaves the committed journal intact; a later mutation or unload retries.
        try? saveGraph(force: true)
    }
    func removeSnapshots(space: String, keeping: String? = nil, olderThan: Int64? = nil) throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        let prefix = SemanticSource.hash(Data(space.utf8)) + "-"
        for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            if let olderThan {
                let graphFile = file.pathExtension == "json" ? file.deletingPathExtension() : file
                guard let suffix = graphFile.deletingPathExtension().lastPathComponent.split(separator: "-").last,
                    let sequence = Int64(suffix), sequence < olderThan
                else { continue }
            }
            if file.lastPathComponent.hasPrefix(prefix),
                file.lastPathComponent != keeping, file.lastPathComponent != keeping.map({ $0 + ".json" })
            {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
