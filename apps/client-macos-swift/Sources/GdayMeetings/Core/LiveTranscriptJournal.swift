import Foundation

/// Ordered, bounded delivery of transcript changes to an append-only file.
/// Encoding and file access run on the utility queue, never on the caller.
final class LiveTranscriptJournal<Record: Sendable>: @unchecked Sendable {
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
    struct Format {
        var header: Data
        var encode: (Record) throws -> Data
        /// Restores encoder state as well as decoding the committed prefix.
        var restore: (Data) throws -> (records: [Record], committedBytes: Int)
    }
    private let format: Format
    private let queue = DispatchQueue(label: "meetings.live-transcript-journal", qos: .utility)
    private let lock = NSLock()
    // Protected by lock; enqueueing also happens under lock to preserve order.
    private var pending = 0
    private var failure: Error?
    // Accessed only on queue.
    private var handle: FileHandle?
    private var writeFailure: Error?

    init(url: URL, limit: Int = 256, maximumRecordBytes: Int = 4 * 1024 * 1024, format: Format) {
        self.url = url
        self.limit = max(1, limit)
        self.maximumRecordBytes = max(1, maximumRecordBytes)
        self.format = format
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
                let handle = try open()
                let data = try format.encode(record)
                guard data.count <= maximumRecordBytes else { throw Failure.oversized }
                try handle.write(contentsOf: data)
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
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: format.header, attributes: [.posixPermissions: 0o600])
            else { throw Failure.create }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let data = try Data(contentsOf: url)
        // Validate before appending. Only an interrupted final write is repairable.
        let committedBytes = try format.restore(data).committedBytes
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

    deinit { try? handle?.close() }
}
