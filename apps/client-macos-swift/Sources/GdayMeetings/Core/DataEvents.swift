import Foundation

/// Every provider response carries the same data-flow receipt, independently of its payload.
protocol ProviderDataResult {
    associatedtype Value
    var value: Value { get }
    var dataFlow: DataFlow { get }
}

struct ProviderResult<Value>: ProviderDataResult {
    let value: Value
    let dataFlow: DataFlow
}
extension ProviderResult: Sendable where Value: Sendable {}

struct DataFlow: Codable, Equatable, Sendable {
    enum Location: String, Codable, Sendable { case local, remote }
    var location: Location
    /// Missing only in legacy receipts. Names must never be used to infer identity.
    private(set) var targetID: UUID?
    var targetName: String
    var domain: String?
    var requestBytes: Int?
    var responseBytes: Int?
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    var bodies: [String]
    /// Explicit meeting-relative paths, separate from human-readable payload descriptions.
    var filePaths: [String]
    var purpose: String

    enum CodingKeys: String, CodingKey {
        case location, targetID, targetName, domain, requestBytes, responseBytes, startedAt, endedAt, duration, bodies,
            filePaths, purpose
    }
    init(
        location: Location, targetID: UUID, targetName: String, domain: String? = nil, requestBytes: Int? = nil,
        responseBytes: Int? = nil, startedAt: Date, endedAt: Date? = nil, bodies: [String], filePaths: [String] = [],
        purpose: String
    ) {
        self.location = location
        self.targetID = targetID
        self.targetName = targetName
        self.domain = domain
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bodies = bodies
        self.filePaths = filePaths
        self.purpose = purpose
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        location = try c.decode(Location.self, forKey: .location)
        targetID = try c.decodeIfPresent(UUID.self, forKey: .targetID)
        targetName = try c.decode(String.self, forKey: .targetName)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        requestBytes = try c.decodeIfPresent(Int.self, forKey: .requestBytes)
        responseBytes = try c.decodeIfPresent(Int.self, forKey: .responseBytes)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        bodies = try c.decode([String].self, forKey: .bodies)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        purpose = try c.decode(String.self, forKey: .purpose)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(location, forKey: .location)
        try c.encodeIfPresent(targetID, forKey: .targetID)
        try c.encode(targetName, forKey: .targetName)
        try c.encode(domain, forKey: .domain)
        try c.encode(requestBytes, forKey: .requestBytes)
        try c.encode(responseBytes, forKey: .responseBytes)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(duration, forKey: .duration)
        try c.encode(bodies, forKey: .bodies)
        try c.encode(filePaths, forKey: .filePaths)
        try c.encode(purpose, forKey: .purpose)
    }

    /// Resolve only a saved identity; deleted providers and legacy receipts keep their snapshot.
    func resolvedTargetName(providers: [UUID: ServiceProvider]) -> String {
        guard let targetID else { return targetName }
        if targetID == ThisMacProvider.id { return "This Mac" }
        return providers[targetID]?.name ?? targetName
    }
}

/// Scoped measurements never retain request bodies, headers, or signed URLs.
final class ProviderTransferMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var received = 0
    private var hasMeasurement = false
    private var unknownResponse = false
    func record(sent: Int, received: Int?) {
        lock.lock()
        defer { lock.unlock() }
        hasMeasurement = true
        self.sent += sent
        if let received {
            self.received += received
        }
        else {
            unknownResponse = true
        }
    }
    var sizes: (Int?, Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (hasMeasurement ? sent : nil, hasMeasurement && !unknownResponse ? received : nil)
    }
}

enum ProviderDataOperation {
    @TaskLocal static var metrics: ProviderTransferMetrics?

    static func perform<Value>(
        targetID: UUID, target: String, endpoint: String, bodies: [String], filePaths: [String] = [], purpose: String,
        operation: () async throws -> Value
    ) async throws -> ProviderResult<Value> {
        let start = Date()
        let measurements = ProviderTransferMetrics()
        let value = try await $metrics.withValue(measurements) { try await operation() }
        let sizes = measurements.sizes
        let host = URL(string: endpoint)?.host
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
        return ProviderResult(
            value: value,
            dataFlow: DataFlow(
                location: local ? .local : .remote, targetID: targetID, targetName: target, domain: host,
                requestBytes: sizes.0, responseBytes: sizes.1, startedAt: start, endedAt: Date(),
                bodies: bodies, filePaths: filePaths, purpose: purpose))
    }
}

struct MeetingDataEvent: Codable, Identifiable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case created, modified, sent, received }
    var id = UUID()
    var action: Action
    var dataFlow: DataFlow
}

/// Append-only per-meeting history. A damaged or interrupted line cannot hide later events.
enum DataEventJournal {
    static let filename = "data-events.jsonl"
    private static let lock = NSLock()
    static func append(_ event: MeetingDataEvent, directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let file = directory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t create data-events.jsonl.")
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event)
        line.append(10)
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != 10 {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([10]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
    static func read(directory: URL) throws -> [MeetingDataEvent] {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return latestRevisions(
            try Data(contentsOf: file).split(separator: 10).compactMap {
                try? decoder.decode(MeetingDataEvent.self, from: Data($0))
            })
    }
    static func fileChanged(_ file: URL, previous: Data?, directory: URL? = nil) throws {
        guard file.lastPathComponent != filename, let current = try? Data(contentsOf: file), current != previous else {
            return
        }
        let folder = directory ?? file.deletingLastPathComponent()
        let path =
            file.path.hasPrefix(folder.path + "/")
            ? String(file.path.dropFirst(folder.path.count + 1)) : file.lastPathComponent
        let now = Date()
        try append(
            MeetingDataEvent(
                action: previous == nil ? .created : .modified,
                dataFlow: DataFlow(
                    location: .local, targetID: ThisMacProvider.id, targetName: "This Mac",
                    responseBytes: current.count, startedAt: now,
                    endedAt: now,
                    bodies: [path], filePaths: file.path.hasPrefix(folder.path + "/") ? [path] : [],
                    purpose: "Saved file")), directory: folder)
    }
}

extension MeetingStore {
    func recordDataFlow(_ flow: DataFlow, meetingID: UUID, action: MeetingDataEvent.Action = .sent) {
        do {
            try DataEventJournal.append(
                MeetingDataEvent(action: action, dataFlow: flow), directory: directory(for: meetingID))
        }
        catch {
            errorMessage =
                "The operation completed, but its data event couldn’t be saved. \(error.localizedDescription)"
        }
    }
}

extension DataFlow {
    func referencing(file: URL, prepared: URL) -> Self {
        var copy = self
        copy.bodies = [
            file.lastPathComponent
                + (prepared == file ? "" : " (converted to \(prepared.pathExtension.uppercased()) for upload)")
        ]
        copy.filePaths = [file.lastPathComponent]
        return copy
    }
    func referencingAudio(_ files: [URL]) -> Self {
        var copy = self
        copy.bodies =
            files.map { $0.lastPathComponent + " (audio download link)" }
            + bodies.filter { !$0.hasSuffix(" audio link") }
        copy.filePaths = files.map(\.lastPathComponent)
        return copy
    }
}

extension MeetingStore {
    func summaryDataFilePaths(_ meeting: Meeting, messages: [LLMMessage]) -> [String] {
        var paths = ["metadata.json", "content.json"]
        if !meeting.notes.isEmpty { paths.append("notes.md") }
        if !meeting.transcript.isEmpty { paths.append("transcript.jsonl") }
        paths += messages.flatMap { $0.images ?? [] }.map(\.path)
        return paths
    }
    func chatDataFilePaths(_ meeting: Meeting, contextual: Bool = false) -> [String] {
        var paths = ["metadata.json"]
        // Context chat history belongs to the library, not this meeting folder.
        if !contextual { paths.append("content.json") }
        if !meeting.notes.isEmpty { paths.append("notes.md") }
        if !meeting.transcript.isEmpty { paths.append("transcript.jsonl") }
        if !meeting.summary.isEmpty { paths.append("summary.md") }
        return paths
    }
    func summaryDataBodies(_ meeting: Meeting, messages: [LLMMessage]) -> [String] {
        var bodies = ["metadata.json (title, date, duration)", "content.json (language)", "Summary Prompt"]
        if !meeting.notes.isEmpty { bodies.append("notes.md") }
        if !meeting.transcript.isEmpty { bodies.append("transcript.jsonl") }
        if !meeting.personIDs.isEmpty || !meeting.speakers.isEmpty { bodies.append("participant names and notes") }
        bodies += messages.flatMap { $0.images ?? [] }.map { $0.path + " (converted JPEG for summary)" }
        return bodies
    }
    func chatDataBodies(_ meeting: Meeting, contextual: Bool = false) -> [String] {
        var bodies = [
            "metadata.json (title)",
            contextual ? "context-chats.json (library folder)" : "content.json (chat)",
            "chat instructions",
        ]
        if !meeting.notes.isEmpty { bodies.append("notes.md") }
        if !meeting.transcript.isEmpty { bodies.append("transcript.jsonl") }
        if !meeting.summary.isEmpty { bodies.append("summary.md") }
        if !meeting.speakers.isEmpty { bodies.append("speaker names") }
        return bodies
    }
}

extension DataEventJournal {
    static func documentSnapshot(directory: URL) -> [String: Data] {
        Dictionary(
            uniqueKeysWithValues: ["metadata.json", "content.json", "transcript.jsonl", "summary.md"].compactMap {
                name in
                (try? Data(contentsOf: directory.appendingPathComponent(name))).map { (name, $0) }
            })
    }
    static func recordDocuments(directory: URL, previous: [String: Data]) throws {
        for name in ["metadata.json", "content.json", "transcript.jsonl", "summary.md"] {
            try fileChanged(directory.appendingPathComponent(name), previous: previous[name], directory: directory)
        }
    }
    /// Payloads such as audio and images are never read merely to log their creation.
    static func fileSaved(_ file: URL, action: MeetingDataEvent.Action, directory: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let path =
            file.path.hasPrefix(directory.path + "/")
            ? String(file.path.dropFirst(directory.path.count + 1)) : file.lastPathComponent
        let now = Date()
        try append(
            MeetingDataEvent(
                action: action,
                dataFlow: DataFlow(
                    location: .local, targetID: ThisMacProvider.id, targetName: "This Mac", responseBytes: size,
                    startedAt: now, endedAt: now,
                    bodies: [path], filePaths: file.path.hasPrefix(directory.path + "/") ? [path] : [],
                    purpose: "Saved file")), directory: directory)
    }
    struct History: Sendable {
        let events: [MeetingDataEvent]
        let unreadableLines: Int
    }
    static func history(directory: URL) throws -> History {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return History(events: [], unreadableLines: 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let lines = try Data(contentsOf: file).split(separator: 10)
        let events = lines.compactMap { try? decoder.decode(MeetingDataEvent.self, from: Data($0)) }
        return History(events: latestRevisions(events), unreadableLines: lines.count - events.count)
    }
    /// Live sessions append their end time with the same event ID; prior bytes stay untouched.
    private static func latestRevisions(_ events: [MeetingDataEvent]) -> [MeetingDataEvent] {
        var result: [MeetingDataEvent] = []
        var indices: [UUID: Int] = [:]
        for event in events {
            if let index = indices[event.id] {
                result[index] = event
            }
            else {
                indices[event.id] = result.count
                result.append(event)
            }
        }
        return result.sorted { $0.dataFlow.startedAt < $1.dataFlow.startedAt }
    }
}

extension DataEventJournal {
    static let writeFailure = Notification.Name("GdayDataEventWriteFailure")
    /// Audit failure must not turn successful file persistence into an operation failure or retry.
    static func recordSavedFile(_ file: URL, previous: Data?, directory: URL? = nil) {
        do { try fileChanged(file, previous: previous, directory: directory) }
        catch {
            NotificationCenter.default.post(name: writeFailure, object: directory ?? file.deletingLastPathComponent())
        }
    }
    static func recordCreatedFile(_ file: URL, directory: URL) {
        recordFile(file, action: .created, directory: directory)
    }
    static func recordFile(_ file: URL, action: MeetingDataEvent.Action, directory: URL) {
        do { try fileSaved(file, action: action, directory: directory) }
        catch { NotificationCenter.default.post(name: writeFailure, object: directory) }
    }
}
