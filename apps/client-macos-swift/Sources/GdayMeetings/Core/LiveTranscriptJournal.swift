import Foundation

/// Ordered, bounded delivery of transcript changes to an append-only file.
/// Encoding and file access run on the utility queue, never on the caller.
final class LiveTranscriptJournal<Record: Codable & Sendable>: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case full
        case corrupt
        case create
        case oversized

        var errorDescription: String? {
            switch self {
            case .full: "Live transcript saving couldn't keep up. Some changes weren't saved."
            case .corrupt: "Couldn't read the live transcript journal. The file contains an invalid record."
            case .create: "Couldn't create the live transcript journal."
            case .oversized: "Couldn't save a live transcript change because it was too large."
            }
        }
    }

    private let url: URL
    private let limit: Int
    private let maximumRecordBytes: Int
    private struct Header: Codable {
        let format: String
        let version: Int
    }
    private let queue = DispatchQueue(label: "meetings.live-transcript-journal", qos: .utility)
    private let lock = NSLock()
    // Protected by lock; enqueueing also happens under lock to preserve order.
    private var pending = 0
    private var failure: Error?
    // Accessed only on queue.
    private var handle: FileHandle?
    private var writeFailure: Error?

    init(url: URL, limit: Int = 256, maximumRecordBytes: Int = 4 * 1024 * 1024) {
        self.url = url
        self.limit = max(1, limit)
        self.maximumRecordBytes = max(1, maximumRecordBytes)
    }

    /// False means this record was not accepted. The error is retained by flush;
    /// later records are rejected so replay can never silently skip a mutation.
    @discardableResult
    func append(_ record: Record) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return false }
        guard pending < limit else {
            failure = Failure.full
            return false
        }
        pending += 1
        queue.async { [self] in
            do {
                if let writeFailure { throw writeFailure }
                var data = try JSONEncoder().encode(record)
                guard data.count <= maximumRecordBytes else { throw Failure.oversized }
                data.append(0x0A)
                try open().write(contentsOf: data)
            }
            catch {
                writeFailure = error
                recordFailure(error)
            }
            lock.lock()
            pending -= 1
            lock.unlock()
        }
        return true
    }

    /// Waits for accepted changes and synchronizes them before reporting failure.
    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            queue.async { [self] in
                do {
                    try handle?.synchronize()
                }
                catch { recordFailure(error) }
                lock.lock()
                let result = failure
                lock.unlock()
                if let result {
                    continuation.resume(throwing: result)
                }
                else {
                    continuation.resume()
                }
            }
            lock.unlock()
        }
    }

    private func recordFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    private func open() throws -> FileHandle {
        if let handle { return handle }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: url.path) {
            var header = try JSONEncoder().encode(Header(format: "gday-live-transcript", version: 1))
            header.append(0x0A)
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: header, attributes: [.posixPermissions: 0o600])
            else { throw Failure.create }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let data = try Data(contentsOf: url)
        // Validate before appending. Only an interrupted final write is repairable.
        _ = try Self.decode(data)
        let committedBytes = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        let opened = try FileHandle(forWritingTo: url)
        do {
            if committedBytes < data.count { try opened.truncate(atOffset: UInt64(committedBytes)) }
            try opened.seekToEnd()
            handle = opened
            return opened
        }
        catch {
            try? opened.close()
            throw error
        }
    }

    /// A newline commits one record. An unterminated tail is an interrupted
    /// append; malformed committed records fail instead of hiding missing data.
    static func read(from url: URL) throws -> [Record] {
        try decode(Data(contentsOf: url))
    }

    private static func decode(_ data: Data) throws -> [Record] {
        let decoder = JSONDecoder()
        var records: [Record] = []
        guard let headerEnd = data.firstIndex(of: 0x0A),
            let header = try? decoder.decode(Header.self, from: data[..<headerEnd]),
            header.format == "gday-live-transcript", header.version == 1
        else { throw Failure.corrupt }
        var start = data.index(after: headerEnd)
        while start < data.endIndex, let end = data[start...].firstIndex(of: 0x0A) {
            guard end > start else { throw Failure.corrupt }
            do { records.append(try decoder.decode(Record.self, from: data[start..<end])) }
            catch { throw Failure.corrupt }
            start = data.index(after: end)
        }
        return records
    }

    deinit { try? handle?.close() }
}
