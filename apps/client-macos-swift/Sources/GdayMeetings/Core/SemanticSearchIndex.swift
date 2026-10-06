import Accelerate
import CSQLite
import CryptoKit
import Foundation

struct SemanticWindow: Codable, Sendable {
    var id: String
    var text: String
    var kind: String
    var segmentID: UUID?
    var start: Double?
    var end: Double?
    var track: String?
    var people: Set<UUID>
    var vector: [Double] = []
}

struct SemanticMeetingArtifact: Codable, Sendable {
    let space: String
    let meetingID: UUID
    let revision: String
    let windows: [SemanticWindow]
}

enum SemanticSource {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(folder: URL) throws -> String {
        try MeetingFolderLocation.validate(
            folder, directory: folder.deletingLastPathComponent().deletingLastPathComponent())
        let names = [
            "metadata.json", "content.json", "transcript.jsonl", "transcript.json", "live-transcript.json", "notes.md",
            "summary.md",
            LiveTranscriptProjection.checkpointName,
        ]
        var fields: [String] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                fields.append(name + ":missing")
                continue
            }
            let value = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard value.isSymbolicLink != true else { throw SearchProviderError.invalidResponse }
            fields.append("\(name):\(value.fileSize ?? 0):\(value.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return hash(Data(fields.joined(separator: "|").utf8))
    }
    static func windows(_ meeting: Meeting) -> [SemanticWindow] {
        var windows: [SemanticWindow] = []
        func append(text: String, kind: String, segments: [TranscriptSegment] = []) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let speakers = Set(
                segments.compactMap { segment -> UUID? in
                    guard let speaker = meeting.speakers.first(where: { $0.id == segment.speakerID }),
                        speaker.confirmed, speaker.sourcePlaceholder == nil
                    else { return nil }
                    return speaker.personID
                })
            let source = Set(segments.compactMap(\.source)).count == 1 ? segments.first?.source : nil
            let track = source.map { $0 == .microphone ? "microphone" : "system" }
            let audio = track.flatMap { prefix in meeting.audioFiles.first { $0.hasPrefix(prefix + ".") } }
            let identity = "\(kind):\(segments.map { $0.id.uuidString }.joined(separator: ",")):\(text)"
            windows.append(
                .init(
                    id: hash(Data(identity.utf8)), text: text, kind: kind,
                    segmentID: segments.first?.id, start: segments.map(\.start).min(),
                    end: segments.map(\.end).max(), track: audio, people: speakers))
        }
        append(text: meeting.title, kind: "title")
        append(text: NotesReadingDocument(meeting.notes).searchableText, kind: "notes")
        append(text: NotesReadingDocument(meeting.summary).searchableText, kind: "summary")
        // Bounded adjacent turns retain local conversational context. Mixed tracks
        // have timestamp evidence, but no single-track playback attribution.
        var current: [TranscriptSegment] = []
        for segment in meeting.transcript.sorted(by: { $0.start < $1.start }) where !segment.text.isEmpty {
            if let first = current.first, let last = current.last,
                segment.end - first.start > 30 || segment.start - last.end > 5
                    || current.reduce(0, { $0 + $1.text.count }) + segment.text.count > 1000
            {
                append(text: current.map(\.text).joined(separator: " "), kind: "transcript", segments: current)
                current = []
            }
            current.append(segment)
        }
        append(text: current.map(\.text).joined(separator: " "), kind: "transcript", segments: current)
        return windows
    }
}

/// A disposable projection with little-endian FP32 vectors, scanned one meeting at a time.
actor SemanticSearchIndex {
    static let module = IndexDatabase.Module(
        namespace: "provider_semantic", version: 2,
        tables: [
            .init(
                name: "provider_semantic_meetings",
                definition:
                    "(space TEXT NOT NULL,meeting TEXT NOT NULL,fingerprint TEXT NOT NULL,artifact BLOB NOT NULL,vectors BLOB NOT NULL,dimensions INTEGER NOT NULL,PRIMARY KEY(space,meeting))"
            )
        ], indexes: "", initialValues: "")
    private let connection: IndexDatabase.Connection
    private let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, indexDirectory: URL) throws {
        self.directory = directory
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(Self.module)
    }
    private func bind(_ text: String, _ column: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, column, text, -1, transient)
    }
    func isCurrent(_ id: UUID, space: String, fingerprint: String) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT fingerprint FROM provider_semantic_meetings WHERE space=? AND meeting=?")
        defer { connection.release(statement) }
        bind(space, 1, statement)
        bind(id.uuidString, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) } == fingerprint
    }
    func persist(_ artifact: SemanticMeetingArtifact, fingerprint: String) throws {
        let folder = try MeetingFolderLocation.resolve(id: artifact.meetingID, directory: directory)
        guard try SemanticSource.fingerprint(folder: folder) == fingerprint else {
            throw SearchProviderError.sourceChanged
        }
        let dimensions = artifact.windows.first?.vector.count ?? 0
        guard
            artifact.windows.allSatisfy({ window in
                window.vector.count == dimensions && dimensions > 0
                    && window.vector.allSatisfy(\.isFinite)
                    && abs(window.vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001
            })
        else { throw SearchProviderError.invalidResponse }
        // Keep reusable provider artifacts independent of the disposable SQLite format.
        let data = try JSONEncoder().encode(artifact)
        let coordinates = artifact.windows.flatMap { $0.vector.map { Float($0).bitPattern.littleEndian } }
        let vectors = coordinates.withUnsafeBytes { Data($0) }
        let metadata = SemanticMeetingArtifact(
            space: artifact.space, meetingID: artifact.meetingID, revision: artifact.revision,
            windows: artifact.windows.map { window in
                var metadata = window
                metadata.vector = []
                return metadata
            })
        let metadataData = try JSONEncoder().encode(metadata)
        let saved = folder.appendingPathComponent(
            "providers/local-search/" + SemanticSource.hash(Data(artifact.space.utf8)))
        let canonical = saved.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/providers/") else {
            throw SearchProviderError.invalidResponse
        }
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try data.write(to: saved.appendingPathComponent("embeddings.json"), options: .atomic)
        try connection.write(module: Self.module) {
            let statement = try connection.prepare(
                "INSERT INTO provider_semantic_meetings VALUES(?,?,?,?,?,?) ON CONFLICT(space,meeting) DO UPDATE SET fingerprint=excluded.fingerprint,artifact=excluded.artifact,vectors=excluded.vectors,dimensions=excluded.dimensions"
            )
            defer { connection.release(statement) }
            bind(artifact.space, 1, statement)
            bind(artifact.meetingID.uuidString, 2, statement)
            bind(fingerprint, 3, statement)
            _ = metadataData.withUnsafeBytes {
                sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(metadataData.count), transient)
            }
            if vectors.isEmpty {
                sqlite3_bind_zeroblob(statement, 5, 0)
            }
            else {
                _ = vectors.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(vectors.count), transient)
                }
            }
            sqlite3_bind_int(statement, 6, Int32(dimensions))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
        }
    }
    func reset(space: String) throws {
        try connection.write(module: Self.module) {
            let statement = try connection.prepare("DELETE FROM provider_semantic_meetings WHERE space=?")
            defer { connection.release(statement) }
            bind(space, 1, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
        }
    }
    func remove(_ id: UUID) throws {
        try connection.write(module: Self.module) {
            let statement = try connection.prepare("DELETE FROM provider_semantic_meetings WHERE meeting=?")
            defer { connection.release(statement) }
            bind(id.uuidString, 1, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
        }
    }
    func search(vector: [Double], model: SemanticModelID, request: ProviderSearchRequest, boost: Double) throws
        -> [ProviderSearchResult]
    {
        guard vector.count == model.dimensions, vector.allSatisfy(\.isFinite) else {
            throw SearchProviderError.invalidResponse
        }
        let query = vector.map(Float.init)
        let limit = max(1, min(request.limit, 100))
        let statement = try connection.prepare(
            "SELECT meeting,fingerprint,artifact,vectors,dimensions FROM provider_semantic_meetings WHERE space=? ORDER BY meeting"
        )
        defer { connection.release(statement) }
        bind(model.space, 1, statement)
        var best: [(ProviderSearchResult, Double)] = []
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw connection.failure() }
            guard let rawID = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: rawID)),
                let fingerprint = sqlite3_column_text(statement, 1), let bytes = sqlite3_column_blob(statement, 2),
                let folder = try? MeetingFolderLocation.resolve(id: id, directory: directory),
                (try? SemanticSource.fingerprint(folder: folder)) == String(cString: fingerprint),
                let entry = try? JSONDecoder().decode(
                    MeetingListEntry.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json"))),
                Set(entry.tagIDs).isDisjoint(with: request.excludingTagIDs)
            else { continue }
            let artifact = try JSONDecoder().decode(
                SemanticMeetingArtifact.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))))
            guard artifact.space == model.space, artifact.meetingID == id,
                sqlite3_column_int(statement, 4) == model.dimensions,
                Int(sqlite3_column_bytes(statement, 3)) == artifact.windows.count * model.dimensions
                    * MemoryLayout<Float>.size,
                let vectorBytes = sqlite3_column_blob(statement, 3)
            else { continue }
            // Supported macOS architectures are little-endian. SQLite owns this
            // aligned buffer until the next step; no whole-library vector cache is needed.
            let coordinates = vectorBytes.assumingMemoryBound(to: Float.self)
            for (position, window) in artifact.windows.enumerated() {
                if position.isMultiple(of: 64) { try Task.checkCancellation() }
                let values = coordinates.advanced(by: position * model.dimensions)
                var norm: Float = 0
                var similarity: Float = 0
                vDSP_svesq(values, 1, &norm, vDSP_Length(model.dimensions))
                vDSP_dotpr(query, 1, values, 1, &similarity, vDSP_Length(model.dimensions))
                guard norm.isFinite, similarity.isFinite, abs(norm - 1) < 0.0001
                else { continue }
                let score = SpeakerMatchScore(
                    similarity: Double(similarity), identified: request.identifiedPeople, speakers: window.people,
                    boost: boost)
                let resultID = id.uuidString + ":" + window.id
                if best.count == limit, let last = best.last,
                    score.total < last.1 || (score.total == last.1 && resultID >= last.0.id)
                {
                    continue
                }
                let passage = LibrarySearchResult(
                    id: 0, meetingID: id, title: entry.title, createdAt: entry.createdAt,
                    kind: LibrarySearchKind(rawValue: window.kind) ?? .transcript, segmentID: window.segmentID,
                    start: window.start, excerpt: window.text)
                let audio: ProviderSearchAudioRange? = window.track.flatMap { track in
                    guard let start = window.start, let end = window.end, end > start else { return nil }
                    return .init(filename: track, start: start, duration: end - start)
                }
                let result = ProviderSearchResult(
                    id: resultID, meetingID: id, title: entry.title,
                    excerpt: window.text, sourceRevision: artifact.revision, passage: passage, audio: audio,
                    createdAt: entry.createdAt, scoreBreakdown: score)
                best.append((result, score.total))
                best.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
                if best.count > limit { best.removeLast() }
            }
        }
        return best.map(\.0)
    }
}
