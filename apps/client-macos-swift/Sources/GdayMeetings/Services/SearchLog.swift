import Darwin
import Foundation
import OSLog

/// Each line is an independent, versioned event. Result arrays preserve ranking order.
struct SearchLogEvent: Codable, Sendable {
    var schemaVersion = 1
    var eventID = UUID()
    var timestamp = Date()
    let kind: String
    let requestID: UUID
    var submissionID: UUID? = nil
    var providerID: UUID? = nil
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    var appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    var appRevision = Bundle.main.object(forInfoDictionaryKey: "GdayBuildRevision") as? String ?? "development"
    var appBuiltAt = Bundle.main.object(forInfoDictionaryKey: "GdayBuiltAt") as? String ?? "unknown"
    var request: ProviderSearchRequest? = nil
    var configuration: [String: String]? = nil
    var timingsMS: [String: Double]? = nil
    var snapshot: ProviderSearchSnapshot? = nil
    var retrieval: SearchRetrievalTrace? = nil
    var display: [SearchDisplayResult]? = nil
    var snapshotID: UUID? = nil
    var isFinal: Bool? = nil
    var failures: [String: String]? = nil
    var interaction: SearchInteraction? = nil
    var people: PeopleNameResolution? = nil
    var error: String? = nil
}

struct SearchInteraction: Codable, Sendable {
    let resultID: String
    let meetingID: UUID
    let action: String
    let input: String
    let resultRank: Int
    let groupRank: Int
    let matchRank: Int
    let elapsedSinceDisplayMS: Double
    var signal = "implicit_relevance"
}

struct SearchRetrievalTrace: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        let key: Int64
        let resultID: String
        let sourceRevision: String
        let sourceFingerprint: String
        let annRank: Int?
        let annDistance: Float?
        let speakerUnion: Bool
        let accepted: Bool
        let score: SpeakerMatchScore?
    }
    struct Round: Codable, Sendable {
        let candidates: [Candidate]
    }
    var indexEpoch: String?
    var indexSequence: Int64 = 0
    var rounds: [Round] = []
    var reranked: [String] = []
    var timingsMS: [String: Double] = [:]
}

/// A serial queue preserves event order without doing file I/O on the UI thread.
/// The file lock also serializes appenders in other processes sharing this library.
struct SearchLog: Sendable {
    let directory: URL
    let providerID: UUID
    private static let queue = DispatchQueue(label: "com.gdaymeetings.search-log", qos: .utility)
    private static let logger = Logger(subsystem: "com.gdaymeetings.macos", category: "SearchLog")

    var fileURL: URL {
        directory.appendingPathComponent("providers").appendingPathComponent(providerID.uuidString)
            .appendingPathComponent("search-log.jsonl")
    }
    func record(_ event: SearchLogEvent) {
        var event = event
        event.providerID = providerID
        let captured = event
        Self.queue.async {
            do { try append(captured) }
            catch {
                Self.logger.error(
                    "Couldn’t save search evaluation event: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    static func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    func append(_ event: SearchLogEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)
        // Validate each owned directory before descending; never follow a provider symlink.
        var parent = directory
        for component in ["providers", providerID.uuidString] {
            parent.appendPathComponent(component)
            guard mkdir(parent.path, 0o700) == 0 || errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let attributes = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isSymbolicLink != true, attributes.isDirectory == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        let descriptor = Darwin.open(fileURL.path, O_CREAT | O_APPEND | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        // Preserve a torn final line while ensuring subsequent events remain independently readable.
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0 else { throw POSIXError(.EIO) }
        if end > 0 {
            var last: UInt8 = 0
            guard pread(descriptor, &last, 1, end - 1) == 1 else { throw POSIXError(.EIO) }
            if last != 0x0A { data.insert(0x0A, at: 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
