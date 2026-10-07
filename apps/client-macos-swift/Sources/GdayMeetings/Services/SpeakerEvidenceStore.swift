import Darwin
import Foundation

/// Append-only evidence; a torn final line is ignored, committed corruption is an error.
/// Audio stays in the source tracks. This journal stores only compact timed evidence.
actor SpeakerEvidenceStore {
    static let fileName = "speaker-evidence.jsonl"
    private struct Gap: Codable {
        var source: String
        var start: Double
        var end: Double
        var reason: String
    }
    private struct Record: Codable {
        var version = 1
        var sample: SpeakerEvidenceSample?
        var activity: [SpeakerEvidenceActivity]?
        var window: SpeakerEvidenceWindow?
        var complete: Bool?
        var gap: Gap?
    }
    private let url: URL
    private var handle: FileHandle?
    private var failure: Error?
    private var sealed = false

    init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    func append(_ sample: SpeakerEvidenceSample) throws {
        try write(Record(sample: sample))
    }

    func append(_ activity: [SpeakerEvidenceActivity], window: SpeakerEvidenceWindow? = nil) throws {
        guard !activity.isEmpty || window != nil else { return }
        guard window?.isValid != false else { throw CocoaError(.fileWriteUnknown) }
        try write(Record(activity: activity, window: window))
    }

    func appendGap(source: String, start: Double, end: Double, reason: String) throws {
        try write(Record(gap: Gap(source: source, start: start, end: end, reason: reason)))
    }

    private func write(_ record: Record) throws {
        if let failure { throw failure }
        guard !sealed else { throw CocoaError(.fileWriteUnknown) }
        do {
            if handle == nil {
                let opened = try Self.openFile(url, writable: true)
                do {
                    // Validate committed records before recovering an incomplete final append.
                    let committed = try Self.scan(opened) { _ in }
                    try opened.truncate(atOffset: committed)
                    try opened.seekToEnd()
                }
                catch {
                    try? opened.close()
                    throw error
                }
                handle = opened
            }
            var bytes = try JSONEncoder().encode(record)
            bytes.append(0x0A)
            try handle?.write(contentsOf: bytes)
        }
        catch {
            failure = error
            throw error
        }
    }

    func finish(complete: Bool = true) throws {
        if let failure { throw failure }
        guard !sealed else { return }
        try write(Record(complete: complete))
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        sealed = true
    }

    /// Partial recording evidence remains inspectable, but cannot silently qualify
    /// as a completed input for automatic consolidation.
    static func isComplete(directory: URL) throws -> Bool {
        let url = directory.appendingPathComponent(fileName)
        try PrivateTranscriptFile.validatePath(name: fileName, at: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var complete = false
        let committed = try scan(url) { complete = $0.complete == true }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return complete && size?.uint64Value == committed
    }

    static func read(directory: URL) throws -> SpeakerEvidenceDocument {
        let url = directory.appendingPathComponent(fileName)
        try PrivateTranscriptFile.validatePath(name: fileName, at: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SpeakerEvidenceDocument(samples: [], activity: [])
        }
        var document = SpeakerEvidenceDocument()
        _ = try scan(url) { record in
            if let sample = record.sample { document.samples.append(sample) }
            document.activity.append(contentsOf: record.activity ?? [])
            if let window = record.window {
                guard
                    (record.activity ?? []).allSatisfy({
                        $0.source == window.source && window.localSpeakerIDs.contains($0.localSpeakerID)
                            && $0.start.isFinite && $0.end.isFinite && $0.start >= window.publicationStart
                            && $0.end > $0.start && $0.end <= window.observedEnd
                    })
                else { throw CocoaError(.fileReadCorruptFile) }
                try document.recordWindow(window)
            }
        }
        return document
    }

    private static func scan(_ url: URL, visit: (Record) throws -> Void) throws -> UInt64 {
        let file = try openFile(url, writable: false)
        defer { try? file.close() }
        return try scan(file, visit: visit)
    }

    private static func scan(_ file: FileHandle, visit: (Record) throws -> Void) throws -> UInt64 {
        try file.seek(toOffset: 0)
        var pending = Data()
        var committed: UInt64 = 0
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let count = pending.distance(from: pending.startIndex, to: newline) + 1
                guard count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                let record = try JSONDecoder().decode(Record.self, from: pending.prefix(count - 1))
                guard record.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                try visit(record)
                pending.removeFirst(count)
                committed += UInt64(count)
            }
            guard pending.count < 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        }
        return committed
    }

    private static func openFile(_ url: URL, writable: Bool) throws -> FileHandle {
        let folder = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(folder) }
        let flags = (writable ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let descriptor = openat(folder, url.lastPathComponent, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            !writable || fchmod(descriptor, mode_t(0o600)) == 0
        else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

}
