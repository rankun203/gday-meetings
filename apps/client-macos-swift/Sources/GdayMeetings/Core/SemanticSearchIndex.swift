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

/// SQLite holds recoverable packed vectors; only the INT8 graph is resident.
actor SemanticSearchIndex {
    static let module = IndexDatabase.Module(
        namespace: "provider_semantic", version: 3,
        tables: [
            .init(
                name: "provider_semantic_meetings",
                definition:
                    "(space TEXT NOT NULL,meeting TEXT NOT NULL,fingerprint TEXT NOT NULL,entry BLOB NOT NULL,revision TEXT NOT NULL,PRIMARY KEY(space,meeting))"
            ),
            .init(
                name: "provider_semantic_windows",
                definition:
                    "(key INTEGER PRIMARY KEY AUTOINCREMENT,space TEXT NOT NULL,meeting TEXT NOT NULL,identity TEXT NOT NULL,metadata BLOB NOT NULL,fp32 BLOB NOT NULL,int8 BLOB NOT NULL,UNIQUE(space,meeting,identity))"
            ),
            .init(
                name: "provider_semantic_people",
                definition:
                    "(space TEXT NOT NULL,person TEXT NOT NULL,key INTEGER NOT NULL,PRIMARY KEY(space,person,key))"),
            .init(
                name: "provider_semantic_tags",
                definition:
                    "(space TEXT NOT NULL,tag TEXT NOT NULL,meeting TEXT NOT NULL,PRIMARY KEY(space,tag,meeting))"),
            .init(
                name: "provider_semantic_state",
                definition:
                    "(space TEXT PRIMARY KEY,epoch TEXT NOT NULL,dimensions INTEGER NOT NULL,sequence INTEGER NOT NULL DEFAULT 0,checkpoint INTEGER NOT NULL DEFAULT 0)"
            ),
            .init(
                name: "provider_semantic_journal",
                definition:
                    "(sequence INTEGER PRIMARY KEY AUTOINCREMENT,space TEXT NOT NULL,key INTEGER NOT NULL,int8 BLOB)"),
        ],
        indexes:
            "CREATE INDEX IF NOT EXISTS provider_semantic_windows_meeting ON provider_semantic_windows(space,meeting); CREATE INDEX IF NOT EXISTS provider_semantic_people_key ON provider_semantic_people(key); CREATE INDEX IF NOT EXISTS provider_semantic_journal_space ON provider_semantic_journal(space,sequence)",
        initialValues: "")
    let connection: IndexDatabase.Connection
    let directory: URL
    let cacheDirectory: URL
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var graph: SemanticHNSWGraph?
    var graphSpace: String?
    var graphEpoch: String?
    var graphNeedsSave = false
    var graphSequence: Int64 = 0
    var changesSinceCheckpoint = 0
    var lastCheckpoint = ContinuousClock.now
    var checkpointTask: Task<Void, Never>?

    init(directory: URL, indexDirectory: URL) throws {
        self.directory = directory
        cacheDirectory = indexDirectory.appendingPathComponent(".index-search-graphs", isDirectory: true)
        guard
            cacheDirectory.resolvingSymlinksInPath().deletingLastPathComponent().resolvingSymlinksInPath().path
                == indexDirectory.resolvingSymlinksInPath().path
        else { throw SearchProviderError.invalidResponse }
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(Self.module)
    }
    func bind(_ text: String, _ column: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, column, text, -1, transient)
    }
    func bind(_ data: Data, _ column: Int32, _ statement: OpaquePointer) {
        if data.isEmpty {
            sqlite3_bind_zeroblob(statement, column, 0)
        }
        else {
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, column, $0.baseAddress, Int32(data.count), transient)
            }
        }
    }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
    func execute(_ sql: String, strings: [String] = []) throws {
        let statement = try connection.prepare(sql)
        defer { connection.release(statement) }
        for (offset, value) in strings.enumerated() { bind(value, Int32(offset + 1), statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
    }
    func keys(_ sql: String, strings: [String]) throws -> [Int64] {
        let statement = try connection.prepare(sql)
        defer { connection.release(statement) }
        for (offset, value) in strings.enumerated() { bind(value, Int32(offset + 1), statement) }
        var values: [Int64] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return values }
            guard step == SQLITE_ROW else { throw connection.failure() }
            values.append(sqlite3_column_int64(statement, 0))
        }
    }
    func isCurrent(_ id: UUID, space: String, fingerprint: String) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT fingerprint FROM provider_semantic_meetings WHERE space=? AND meeting=?")
        defer { connection.release(statement) }
        bind(space, 1, statement)
        bind(id.uuidString, 2, statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return false }
        guard step == SQLITE_ROW else { throw connection.failure() }
        return text(statement, 0) == fingerprint
    }
    func persist(_ artifact: SemanticMeetingArtifact, fingerprint: String) throws {
        try autoreleasepool { try persistMeeting(artifact, fingerprint: fingerprint) }
    }
    private func persistMeeting(_ artifact: SemanticMeetingArtifact, fingerprint: String) throws {
        try Task.checkCancellation()
        let folder = try MeetingFolderLocation.resolve(id: artifact.meetingID, directory: directory)
        guard try SemanticSource.fingerprint(folder: folder) == fingerprint else {
            throw SearchProviderError.sourceChanged
        }
        let packed = try PackedSemanticArtifact(artifact)
        let entryData = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        let entry = try JSONDecoder().decode(MeetingListEntry.self, from: entryData)
        try packed.save(folder: folder)
        do {
            try connection.write(module: Self.module) {
                let dimensions =
                    packed.dimensions == 0
                    ? (SemanticModelID.allCases.first { $0.space == artifact.space }?.dimensions ?? 384)
                    : packed.dimensions
                if let state = try state(space: artifact.space) {
                    guard state.dimensions == dimensions else { throw SearchProviderError.invalidResponse }
                }
                else {
                    try execute(
                        "INSERT INTO provider_semantic_state(space,epoch,dimensions) VALUES(?,?,?)",
                        strings: [artifact.space, UUID().uuidString, String(dimensions)])
                }
                let existing = try retainedWindows(artifact)
                let meeting = try connection.prepare(
                    "INSERT INTO provider_semantic_meetings VALUES(?,?,?,?,?) ON CONFLICT(space,meeting) DO UPDATE SET fingerprint=excluded.fingerprint,entry=excluded.entry,revision=excluded.revision"
                )
                defer { connection.release(meeting) }
                bind(artifact.space, 1, meeting)
                bind(artifact.meetingID.uuidString, 2, meeting)
                bind(fingerprint, 3, meeting)
                bind(entryData, 4, meeting)
                bind(artifact.revision, 5, meeting)
                guard sqlite3_step(meeting) == SQLITE_DONE else { throw connection.failure() }
                try execute(
                    "DELETE FROM provider_semantic_tags WHERE space=? AND meeting=?",
                    strings: [artifact.space, artifact.meetingID.uuidString])
                for tag in entry.tagIDs {
                    try execute(
                        "INSERT INTO provider_semantic_tags VALUES(?,?,?)",
                        strings: [artifact.space, tag.uuidString, artifact.meetingID.uuidString])
                }
                for (position, window) in packed.metadata.windows.enumerated() {
                    try Task.checkCancellation()
                    let f32 = packed.fp32.subdata(in: position * dimensions * 4..<(position + 1) * dimensions * 4)
                    let i8 = packed.int8.subdata(in: position * dimensions..<(position + 1) * dimensions)
                    let statement = try connection.prepare(
                        "INSERT INTO provider_semantic_windows(space,meeting,identity,metadata,fp32,int8) VALUES(?,?,?,?,?,?) ON CONFLICT(space,meeting,identity) DO UPDATE SET metadata=excluded.metadata,fp32=excluded.fp32,int8=excluded.int8 RETURNING key"
                    )
                    bind(artifact.space, 1, statement)
                    bind(artifact.meetingID.uuidString, 2, statement)
                    bind(window.id, 3, statement)
                    bind(try JSONEncoder().encode(window), 4, statement)
                    bind(f32, 5, statement)
                    bind(i8, 6, statement)
                    let step = sqlite3_step(statement)
                    guard step == SQLITE_ROW else {
                        let error = connection.failure()
                        connection.release(statement)
                        throw error
                    }
                    let key = sqlite3_column_int64(statement, 0)
                    let done = sqlite3_step(statement)
                    connection.release(statement)
                    guard done == SQLITE_DONE else { throw connection.failure() }
                    try execute("DELETE FROM provider_semantic_people WHERE key=?", strings: [String(key)])
                    for person in window.people {
                        let relation = try connection.prepare("INSERT INTO provider_semantic_people VALUES(?,?,?)")
                        bind(artifact.space, 1, relation)
                        bind(person.uuidString, 2, relation)
                        sqlite3_bind_int64(relation, 3, key)
                        let step = sqlite3_step(relation)
                        connection.release(relation)
                        guard step == SQLITE_DONE else { throw connection.failure() }
                    }
                    if existing[window.id] != i8 { try journal(space: artifact.space, key: key, vector: i8) }
                }
                // Recheck after file decoding and packed writes, before publishing the projection.
                guard try SemanticSource.fingerprint(folder: folder) == fingerprint else {
                    throw SearchProviderError.sourceChanged
                }
                try advanceSequence(space: artifact.space)
            }
            // SQLite commits coordinates and journal together before the native graph changes.
            try refreshGraph(
                space: artifact.space,
                dimensions: packed.dimensions == 0
                    ? (SemanticModelID.allCases.first { $0.space == artifact.space }?.dimensions ?? 384)
                    : packed.dimensions)
            try saveGraph()
        }
        catch {
            discardGraph()
            throw error
        }
    }
    /// Keep unchanged graph keys; an appended passage must not reinsert every old passage.
    func retainedWindows(_ artifact: SemanticMeetingArtifact) throws -> [String: Data] {
        let identities = Set(artifact.windows.map(\.id))
        guard identities.count == artifact.windows.count else { throw SearchProviderError.invalidResponse }
        let statement = try connection.prepare(
            "SELECT key,identity,int8 FROM provider_semantic_windows WHERE space=? AND meeting=?")
        bind(artifact.space, 1, statement)
        bind(artifact.meetingID.uuidString, 2, statement)
        var retained: [String: Data] = [:]
        var removed: [Int64] = []
        defer { connection.release(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw connection.failure() }
            let identity = text(statement, 1)
            if identities.contains(identity) {
                retained[identity] = blob(statement, 2)
            }
            else {
                removed.append(sqlite3_column_int64(statement, 0))
            }
        }
        for key in removed {
            try execute("DELETE FROM provider_semantic_people WHERE key=?", strings: [String(key)])
            try execute("DELETE FROM provider_semantic_windows WHERE key=?", strings: [String(key)])
            try journal(space: artifact.space, key: key, vector: nil)
        }
        return retained
    }
    func deleteMeetingRows(_ id: UUID, space: String) throws {
        let removed = try keys(
            "SELECT key FROM provider_semantic_windows WHERE space=? AND meeting=?", strings: [space, id.uuidString])
        try execute(
            "DELETE FROM provider_semantic_people WHERE key IN (SELECT key FROM provider_semantic_windows WHERE space=? AND meeting=?)",
            strings: [space, id.uuidString])
        for table in ["windows", "tags", "meetings"] {
            try execute(
                "DELETE FROM provider_semantic_\(table) WHERE space=? AND meeting=?", strings: [space, id.uuidString])
        }
        for key in removed { try journal(space: space, key: key, vector: nil) }
    }
    func reset(space: String) throws {
        try connection.write(module: Self.module) {
            for table in ["people", "tags", "windows", "meetings", "journal", "state"] {
                try execute("DELETE FROM provider_semantic_\(table) WHERE space=?", strings: [space])
            }
        }
        if graphSpace == space { discardGraph() }
        try removeSnapshots(space: space)
    }
    func remove(_ id: UUID) throws {
        do {
            try connection.write(module: Self.module) {
                let statement = try connection.prepare("SELECT space FROM provider_semantic_meetings WHERE meeting=?")
                defer { connection.release(statement) }
                bind(id.uuidString, 1, statement)
                var spaces: [String] = []
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw connection.failure() }
                    spaces.append(text(statement, 0))
                }
                for space in spaces {
                    try deleteMeetingRows(id, space: space)
                    try advanceSequence(space: space)
                }
            }
            if let space = graphSpace, let graph { try refreshGraph(space: space, dimensions: graph.dimensions) }
            try saveGraph()
        }
        catch {
            discardGraph()
            throw error
        }
    }
    func unload() {
        // A cache failure cannot discard committed vectors or their replay journal.
        try? saveGraph(force: true)
        discardGraph()
    }
    func discardGraph() {
        checkpointTask?.cancel()
        checkpointTask = nil
        graph = nil
        graphEpoch = nil
        graphSequence = 0
        changesSinceCheckpoint = 0
        graphNeedsSave = false
        graphSpace = nil
    }
    func prepare(model: SemanticModelID) throws {
        try connection.execute("BEGIN")
        do {
            _ = try ensureGraph(space: model.space, dimensions: model.dimensions)
            try connection.execute("COMMIT")
            try saveGraph(force: true)
        }
        catch {
            try? connection.execute("ROLLBACK")
            discardGraph()
            throw error
        }
    }
}
