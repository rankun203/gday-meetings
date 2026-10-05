import CSQLite
import Foundation

struct VoiceSearchIndexReport: Sendable {
    let indexedClips: Int
    let rejectedArtifacts: Int
}

/// Exact retrieval scans one bounded vector at a time. TEMP scores allow ranked
/// offset paging without retaining the corpus or an ever-growing top-K array.
final class LocalVoiceSearchIndex: @unchecked Sendable {
    static let module = IndexDatabase.Module(
        namespace: "provider_clsp", version: 1,
        tables: [
            .init(
                name: "provider_clsp_sources",
                definition:
                    "(id TEXT PRIMARY KEY,meeting TEXT NOT NULL,audio TEXT NOT NULL,revision TEXT NOT NULL,fingerprint BLOB NOT NULL)"
            ),
            .init(
                name: "provider_clsp_clips",
                definition:
                    "(id TEXT PRIMARY KEY,source TEXT NOT NULL,meeting TEXT NOT NULL,start REAL NOT NULL,duration REAL NOT NULL,space TEXT NOT NULL,vector BLOB NOT NULL,artifact TEXT NOT NULL,artifactFingerprint BLOB NOT NULL)"
            ),
            .init(
                name: "provider_clsp_state",
                definition: "(id INTEGER PRIMARY KEY,complete INTEGER NOT NULL,errors INTEGER NOT NULL)"),
        ],
        indexes:
            "CREATE INDEX IF NOT EXISTS provider_clsp_meeting ON provider_clsp_clips(meeting); CREATE INDEX IF NOT EXISTS provider_clsp_source ON provider_clsp_clips(source,id)",
        initialValues: "INSERT OR IGNORE INTO provider_clsp_state VALUES(1,0,0)")

    private let connection: IndexDatabase.Connection
    private let lock = NSRecursiveLock()
    let artifacts: VoiceSearchArtifacts
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let spaceKey =
        VoiceEmbeddingSpace.clsp.model + "@" + VoiceEmbeddingSpace.clsp.revision
        + ":" + VoiceEmbeddingSpace.clsp.preprocessing + ":512:unitL2"

    init(directory: URL, indexDirectory: URL) throws {
        artifacts = VoiceSearchArtifacts(directory: directory.standardizedFileURL.resolvingSymlinksInPath())
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(.library)
        try connection.register(Self.module)
    }
    private func bind(_ value: String, _ position: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, position, value, -1, transient)
    }
    private func bind<T: Encodable>(_ value: T, _ position: Int32, _ statement: OpaquePointer) throws {
        let data = try JSONEncoder().encode(value)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient)
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ statement: OpaquePointer, _ column: Int32) throws -> T {
        guard let bytes = sqlite3_column_blob(statement, column), sqlite3_column_bytes(statement, column) <= 65_536
        else {
            throw SearchProviderError.invalidResponse
        }
        return try JSONDecoder().decode(
            type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
    }

    func source(meetingID: UUID, audioFilename: String) throws -> (URL, MeetingListEntry) {
        guard audioFilename == URL(fileURLWithPath: audioFilename).lastPathComponent,
            !audioFilename.isEmpty, audioFilename != ".", audioFilename != ".."
        else { throw SearchProviderError.invalidResponse }
        let folder = try MeetingFolderLocation.resolve(id: meetingID, directory: artifacts.directory)
        try MeetingFolderLocation.validate(folder, directory: artifacts.directory)
        let metadata = folder.appendingPathComponent("metadata.json")
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SearchProviderError.invalidResponse
        }
        let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: metadata))
        guard entry.id == meetingID, entry.audioFiles.contains(audioFilename) else {
            throw ServiceError("This audio source is no longer part of the meeting.")
        }
        return (folder.appendingPathComponent(audioFilename), entry)
    }
    func meeting(_ id: UUID) throws -> MeetingListEntry {
        let folder = try MeetingFolderLocation.resolve(id: id, directory: artifacts.directory)
        try MeetingFolderLocation.validate(folder, directory: artifacts.directory)
        let entry = try JSONDecoder().decode(
            MeetingListEntry.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json")))
        guard entry.id == id else { throw SearchProviderError.invalidResponse }
        return entry
    }

    func persist(_ artifact: VoiceSearchArtifact, fingerprint: VoiceSourceFingerprint) throws {
        try project(artifact, fingerprint: fingerprint, saveArtifact: true)
    }
    func reuse(
        meetingID: UUID, audioFilename: String, revision: String, start: Double, duration: Double,
        fingerprint: VoiceSourceFingerprint
    ) throws -> Bool {
        let identity = VoiceSearchArtifact(
            meetingID: meetingID, audioFilename: audioFilename, sourceRevision: revision,
            start: start, duration: duration, space: .clsp, vector: [])
        let file = artifacts.url(for: identity)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let existing = try artifacts.read(file)
        guard existing.id == identity.id else { throw SearchProviderError.invalidResponse }
        try project(existing, fingerprint: fingerprint, saveArtifact: false)
        return true
    }
    private func project(_ artifact: VoiceSearchArtifact, fingerprint: VoiceSourceFingerprint, saveArtifact: Bool)
        throws
    {
        try artifact.validate()
        let (audio, _) = try source(meetingID: artifact.meetingID, audioFilename: artifact.audioFilename)
        guard try VoiceSourceFingerprint.read(audio) == fingerprint else {
            throw ServiceError("The audio changed before its embedding could be saved. Build the voice index again.")
        }
        // Commit the authoritative artifact before publishing its derived row.
        if saveArtifact { try artifacts.save(artifact) }
        let artifactFingerprint = try VoiceSourceFingerprint.read(artifacts.url(for: artifact))
        lock.lock()
        defer { lock.unlock() }
        try connection.write(module: Self.module) {
            try upsert(artifact, fingerprint: fingerprint, artifactFingerprint: artifactFingerprint)
        }
    }
    private func upsert(
        _ artifact: VoiceSearchArtifact, fingerprint: VoiceSourceFingerprint,
        artifactFingerprint: VoiceSourceFingerprint
    ) throws {
        let source = try connection.prepare(
            "INSERT INTO provider_clsp_sources VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint"
        )
        defer { connection.release(source) }
        bind(artifact.sourceID, 1, source)
        bind(artifact.meetingID.uuidString, 2, source)
        bind(artifact.audioFilename, 3, source)
        bind(artifact.sourceRevision, 4, source)
        try bind(fingerprint, 5, source)
        try done(source)
        let clip = try connection.prepare(
            "INSERT INTO provider_clsp_clips VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET vector=excluded.vector,artifact=excluded.artifact,artifactFingerprint=excluded.artifactFingerprint"
        )
        defer { connection.release(clip) }
        bind(artifact.id, 1, clip)
        bind(artifact.sourceID, 2, clip)
        bind(artifact.meetingID.uuidString, 3, clip)
        sqlite3_bind_double(clip, 4, artifact.start)
        sqlite3_bind_double(clip, 5, artifact.duration)
        bind(Self.spaceKey, 6, clip)
        try bind(artifact.vector, 7, clip)
        bind(String(artifacts.url(for: artifact).path.dropFirst(artifacts.directory.path.count + 1)), 8, clip)
        try bind(artifactFingerprint, 9, clip)
        try done(clip)
    }
    func rebuild() throws -> VoiceSearchIndexReport {
        lock.lock()
        defer { lock.unlock() }
        try connection.beginStaging(Self.module, preservingRows: false)
        var count = 0
        var rejected = 0
        do {
            try connection.execute(
                "CREATE TEMP TABLE IF NOT EXISTS voice_source_checks(id TEXT PRIMARY KEY,revision TEXT,fingerprint BLOB); DELETE FROM voice_source_checks"
            )
            try artifacts.enumerate { file in
                do {
                    let artifact = try artifacts.read(file)
                    let fingerprint = try verifiedFingerprint(artifact)
                    try upsert(
                        artifact, fingerprint: fingerprint, artifactFingerprint: VoiceSourceFingerprint.read(file))
                    count += 1
                }
                catch is CancellationError { throw CancellationError() }
                catch let error as IndexDatabase.DatabaseError { throw error }
                catch { rejected += 1 }
            }
            try connection.execute("UPDATE provider_clsp_state SET complete=1,errors=\(rejected) WHERE id=1")
            try connection.publishStaging()
            return .init(indexedClips: count, rejectedArtifacts: rejected)
        }
        catch {
            connection.discardStaging()
            throw error
        }
    }
    private func verifiedFingerprint(_ artifact: VoiceSearchArtifact) throws -> VoiceSourceFingerprint {
        if let existing = try sourceFingerprint(artifact.sourceID) { return existing }
        let key = artifact.meetingID.uuidString + ":" + artifact.audioFilename
        let query = try connection.prepare("SELECT revision,fingerprint FROM voice_source_checks WHERE id=?")
        defer { connection.release(query) }
        bind(key, 1, query)
        let status = sqlite3_step(query)
        if status == SQLITE_ROW {
            guard text(query, 0) == artifact.sourceRevision else { throw SearchProviderError.invalidResponse }
            return try decode(VoiceSourceFingerprint.self, query, 1)
        }
        guard status == SQLITE_DONE else { throw connection.failure() }
        let insert = try connection.prepare("INSERT INTO voice_source_checks VALUES(?,?,?)")
        defer { connection.release(insert) }
        bind(key, 1, insert)
        let revision: String
        let fingerprint: VoiceSourceFingerprint
        do {
            let (audio, _) = try source(meetingID: artifact.meetingID, audioFilename: artifact.audioFilename)
            (revision, fingerprint) = try VoiceSearchArtifacts.sourceRevision(audio)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as IndexDatabase.DatabaseError { throw error }
        catch {
            try done(insert)
            throw error
        }
        bind(revision, 2, insert)
        try bind(fingerprint, 3, insert)
        try done(insert)
        guard revision == artifact.sourceRevision else { throw SearchProviderError.invalidResponse }
        return fingerprint
    }
    private func sourceFingerprint(_ id: String) throws -> VoiceSourceFingerprint? {
        let query = try connection.prepare("SELECT fingerprint FROM provider_clsp_sources WHERE id=?")
        defer { connection.release(query) }
        bind(id, 1, query)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw connection.failure() }
        return try decode(VoiceSourceFingerprint.self, query, 0)
    }
    func remove(meetingID: UUID) throws {
        try artifacts.remove(meetingID: meetingID)
        try invalidate(meetingID: meetingID)
    }
    /// Remove disposable vectors after the owning meeting is moved to Trash.
    /// Durable artifacts stay with that folder and can be imported after restore.
    func invalidate(meetingID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.write(module: Self.module) {
            for table in ["provider_clsp_clips", "provider_clsp_sources"] {
                let query = try connection.prepare("DELETE FROM \(table) WHERE meeting=?")
                bind(meetingID.uuidString, 1, query)
                defer { connection.release(query) }
                try done(query)
            }
        }
    }

    func search(
        vector: [Double], request: ProviderSearchRequest,
        emit: ([ProviderSearchResult], Int, Bool) throws -> Void
    ) throws {
        guard vector.count == 512, vector.allSatisfy(\.isFinite),
            abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.002,
            request.after >= 0, request.after <= Int64(Int.max - 100)
        else { throw SearchProviderError.invalidResponse }
        lock.lock()
        defer { lock.unlock() }
        try connection.execute(
            "CREATE TEMP TABLE IF NOT EXISTS voice_scores(meeting TEXT PRIMARY KEY,id TEXT NOT NULL,score REAL NOT NULL); DELETE FROM voice_scores; CREATE INDEX IF NOT EXISTS temp.voice_score_order ON voice_scores(score DESC,id)"
        )
        let query = try connection.prepare(
            "SELECT c.id,c.source,c.meeting,c.start,c.duration,c.vector,s.audio,s.revision,s.fingerprint,c.artifact,c.artifactFingerprint FROM provider_clsp_clips c JOIN provider_clsp_sources s ON s.id=c.source JOIN meetings m ON m.id=c.meeting WHERE c.space=? AND NOT EXISTS(SELECT 1 FROM relations r WHERE r.meeting=c.meeting AND r.kind='tag' AND r.target IN (SELECT value FROM json_each(?))) ORDER BY c.source,c.id"
        )
        defer { connection.release(query) }
        bind(Self.spaceKey, 1, query)
        let excluded = try JSONEncoder().encode(request.excludingTagIDs.map(\.uuidString))
        bind(String(decoding: excluded, as: UTF8.self), 2, query)
        let insert = try connection.prepare(
            "INSERT INTO voice_scores VALUES(?,?,?) ON CONFLICT(meeting) DO UPDATE SET id=excluded.id,score=excluded.score WHERE excluded.score>voice_scores.score OR (excluded.score=voice_scores.score AND excluded.id<voice_scores.id)"
        )
        defer { connection.release(insert) }
        var lastSource: String?
        var validSource = false
        var indexed = 0
        var visited = 0
        let queryNorm = vector.reduce(0) { $0 + $1 * $1 }
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw connection.failure() }
            visited += 1
            let sourceID = text(query, 1)
            if sourceID != lastSource {
                lastSource = sourceID
                validSource = false
                if let meetingID = UUID(uuidString: text(query, 2)),
                    let (audio, _) = try? source(meetingID: meetingID, audioFilename: text(query, 6)),
                    let expected = try? decode(VoiceSourceFingerprint.self, query, 8),
                    let actual = try? VoiceSourceFingerprint.read(audio), expected == actual
                {
                    validSource = true
                }
            }
            guard validSource else { continue }
            let artifactFile = artifacts.directory.appendingPathComponent(text(query, 9))
            guard artifactFile.standardizedFileURL.path.hasPrefix(artifacts.root.standardizedFileURL.path + "/"),
                let expectedArtifact = try? decode(VoiceSourceFingerprint.self, query, 10),
                let actualArtifact = try? VoiceSourceFingerprint.read(artifactFile), expectedArtifact == actualArtifact
            else { continue }
            let candidate = try decode([Double].self, query, 5)
            let candidateNorm = candidate.reduce(0) { $0 + $1 * $1 }
            guard candidate.count == vector.count, candidate.allSatisfy(\.isFinite), abs(candidateNorm - 1) < 0.002
            else { throw SearchProviderError.invalidResponse }
            let score = zip(vector, candidate).reduce(0.0) { $0 + $1.0 * $1.1 } / sqrt(queryNorm * candidateNorm)
            sqlite3_reset(insert)
            bind(text(query, 2), 1, insert)
            bind(text(query, 0), 2, insert)
            sqlite3_bind_double(insert, 3, score)
            try done(insert)
            indexed += 1
            if visited % 256 == 0 { try emit(results(request), indexed, false) }
        }
        let count = try connection.prepare("SELECT count(*) FROM voice_scores")
        defer { connection.release(count) }
        guard sqlite3_step(count) == SQLITE_ROW else { throw connection.failure() }
        try emit(results(request), Int(sqlite3_column_int64(count, 0)), true)
    }
    private func results(_ request: ProviderSearchRequest) throws -> [ProviderSearchResult] {
        let query = try connection.prepare(
            "SELECT c.id,c.meeting,c.start,c.duration,s.audio,s.revision,m.title,m.created FROM voice_scores v JOIN provider_clsp_clips c ON c.id=v.id JOIN provider_clsp_sources s ON s.id=c.source JOIN meetings m ON m.id=c.meeting ORDER BY v.score DESC,v.id LIMIT ? OFFSET ?"
        )
        defer { connection.release(query) }
        sqlite3_bind_int(query, 1, Int32(max(1, min(request.limit, 100))))
        sqlite3_bind_int64(query, 2, request.after)
        var results: [ProviderSearchResult] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW, let meeting = UUID(uuidString: text(query, 1)) else {
                throw connection.failure()
            }
            let start = sqlite3_column_double(query, 2)
            results.append(
                .init(
                    id: text(query, 0), meetingID: meeting, title: text(query, 6),
                    excerpt: "Audio recording", sourceRevision: text(query, 5), passage: nil,
                    audio: .init(filename: text(query, 4), start: start, duration: sqlite3_column_double(query, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 7))))
        }
    }
}
