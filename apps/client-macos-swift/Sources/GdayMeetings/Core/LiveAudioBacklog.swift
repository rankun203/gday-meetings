import AVFoundation
import Darwin

/// A single consumer follows recording-time packets through memory and temporary disk chunks.
/// Capture only reserves and copies bounded PCM; the worker owns every file operation.
final class LiveAudioBacklog: @unchecked Sendable {
    typealias Packet = LiveAudioQueue.Packet
    private static let startupCleanup: Void = cleanupStaleBacklogs(in: FileManager.default.temporaryDirectory)
    private let worker = DispatchQueue(label: "com.gdaymeetings.live-audio-backlog", qos: .userInitiated)
    private let lock = NSLock()
    private let directory: URL
    private let maximumPendingBytes: Int
    private let maximumPendingJobs: Int
    private let chunkBytes: Int
    private var pendingBytes = 0
    private var pendingJobs = 0
    private var accepting = true
    private var discarded = false
    private var failed = false
    private var preparing = true
    private var queuedSeconds = 0.0
    private var losses: [LiveAudioLoss] = []

    // Accessed only by worker. Disk packet metadata lives in the chunks themselves.
    private var memory: [Packet] = []
    private var memorySeconds = 0.0
    private var memoryBytes = 0
    private var diskPackets = 0
    private var diskSpan: LiveAudioLoss?
    private var writeChunk: UInt64 = 0
    private var readChunk: UInt64 = 0
    private var writeBytes = 0
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var lease: FileHandle?
    private var waiter: CheckedContinuation<Packet?, Never>?
    private var finished = false

    init(
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("gday-live-\(UUID())"),
        maximumPendingBytes: Int = 8 * 1024 * 1024, maximumPendingJobs: Int = 1024,
        chunkBytes: Int = 1024 * 1024
    ) {
        self.directory = directory
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingJobs = maximumPendingJobs
        self.chunkBytes = chunkBytes
        worker.async { _ = Self.startupCleanup }
    }

    deinit {
        let directory = directory
        let writer = writer
        let reader = reader
        let lease = lease
        worker.async {
            try? writer?.close()
            try? reader?.close()
            try? FileManager.default.removeItem(at: directory)
            try? lease?.close()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, start: Double) {
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            .reduce(0) { $0 + Int($1.mDataByteSize) }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let end = start + duration
        lock.lock()
        guard accepting, !discarded else {
            lock.unlock()
            return
        }
        guard !failed, preparing || queuedSeconds + duration <= LiveAudioQueue.maximumSeconds,
            bytes <= maximumPendingBytes - pendingBytes, pendingJobs < maximumPendingJobs,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            recordLossLocked(start: start, end: end)
            lock.unlock()
            return
        }
        copy.frameLength = buffer.frameLength
        for (from, to) in zip(
            UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
            UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList))
        {
            if let source = from.mData, let destination = to.mData {
                memcpy(destination, source, Int(from.mDataByteSize))
            }
        }
        let packet = Packet(buffer: copy, start: start)
        pendingBytes += bytes
        pendingJobs += 1
        queuedSeconds += packet.duration
        // Dispatch under the reservation lock so finish cannot overtake accepted packets.
        worker.async { [self] in
            defer {
                lock.lock()
                pendingBytes -= bytes
                pendingJobs -= 1
                lock.unlock()
            }
            guard !isDiscarded else { return }
            lock.lock()
            let hasFailed = failed
            lock.unlock()
            if hasFailed {
                releaseDuration(packet.duration)
                recordLoss(start: start, end: end)
                return
            }
            if let waiter {
                self.waiter = nil
                releaseDuration(packet.duration)
                waiter.resume(returning: packet)
            }
            else if diskPackets == 0, memory.count < maximumPendingJobs,
                memorySeconds + packet.duration <= LiveAudioQueue.maximumSeconds,
                bytes <= maximumPendingBytes - memoryBytes
            {
                memory.append(packet)
                memorySeconds += packet.duration
                memoryBytes += bytes
            }
            else {
                do { try store(packet) }
                catch {
                    releaseDuration(packet.duration)
                    markFailed()
                    recordLoss(start: start, end: end)
                }
            }
        }
        lock.unlock()
    }

    func next() async -> Packet? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.async { [self] in
                    guard !isDiscarded else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if !memory.isEmpty {
                        let packet = memory.removeFirst()
                        memorySeconds = max(0, memorySeconds - packet.duration)
                        memoryBytes -= Self.byteCount(packet.buffer)
                        releaseDuration(packet.duration)
                        continuation.resume(returning: packet)
                    }
                    else if diskPackets > 0 {
                        do {
                            let packet = try readPacket()
                            diskPackets -= 1
                            releaseDuration(packet.duration)
                            if diskPackets == 0 { cleanDisk() }
                            continuation.resume(returning: packet)
                        }
                        catch {
                            markFailed()
                            if let span = diskSpan { recordLoss(start: span.start, end: span.end, exact: false) }
                            cleanDisk()
                            // Future accepted packets are losses after a storage failure.
                            continuation.resume(returning: nil)
                        }
                    }
                    else if finished || hasFailed {
                        cleanDisk()
                        continuation.resume(returning: nil)
                    }
                    else {
                        precondition(waiter == nil, "Live audio has one consumer")
                        waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.discard()
        }
    }

    /// Preserve preparation audio while bounding subsequent live capture. New
    /// packets report gaps until the earlier backlog has caught up.
    func finishPreparation() {
        lock.lock()
        preparing = false
        lock.unlock()
    }

    private func releaseDuration(_ seconds: Double) {
        lock.lock()
        queuedSeconds = max(0, queuedSeconds - seconds)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        accepting = false
        worker.async { [self] in
            finished = true
            if let waiter {
                self.waiter = nil
                cleanDisk()
                waiter.resume(returning: nil)
            }
        }
        lock.unlock()
    }

    func discard() {
        lock.lock()
        accepting = false
        discarded = true
        worker.async { [self] in
            memory.removeAll()
            memoryBytes = 0
            memorySeconds = 0
            cleanDisk()
            waiter?.resume(returning: nil)
            waiter = nil
        }
        lock.unlock()
    }

    func takeDroppedRanges() -> [LiveAudioLoss] {
        lock.lock()
        defer { lock.unlock() }
        let result = losses
        losses.removeAll()
        return result
    }

    var failureDescription: String? {
        hasFailed ? "Couldn’t buffer audio for live transcription. Recording continues." : nil
    }

    private var isDiscarded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return discarded
    }

    private var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    private func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    private func recordLoss(start: Double, end: Double, exact: Bool = true) {
        lock.lock()
        recordLossLocked(start: start, end: end, exact: exact)
        lock.unlock()
    }

    private func recordLossLocked(start: Double, end: Double, exact: Bool = true) {
        if let last = losses.last, start <= last.end + 0.01, end >= last.start - 0.01 {
            losses[losses.count - 1] = LiveAudioLoss(
                start: min(start, last.start), end: max(end, last.end),
                isExact: exact && last.isExact && start <= last.end + 0.000_001 && end >= last.start - 0.000_001)
        }
        else if losses.count < LiveAudioQueue.maximumDroppedRanges {
            losses.append(LiveAudioLoss(start: start, end: end, isExact: exact))
        }
        else if let last = losses.last {
            losses[losses.count - 1] = LiveAudioLoss(
                start: min(start, last.start), end: max(end, last.end), isExact: false)
        }
    }

    private struct Header: Codable {
        let start: Double
        let sampleRate: Double
        let channels: UInt32
        let commonFormat: UInt
        let interleaved: Bool
        let frames: UInt32
        let bufferBytes: [Int]
    }

    private static func byteCount(_ buffer: AVAudioPCMBuffer) -> Int {
        UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
    }

    private func chunkURL(_ index: UInt64) -> URL { directory.appendingPathComponent("\(index).pcm") }

    /// A live process holds this lease across every disk chunk. Cross-process
    /// cleanup requires both an old directory and an obtainable lease.
    static func cleanupStaleBacklogs(in root: URL, now: Date = Date()) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        else { return }
        for directory in entries {
            let name = directory.lastPathComponent
            guard name.hasPrefix("gday-live-"), UUID(uuidString: String(name.dropFirst("gday-live-".count))) != nil,
                let metadata = try? directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                metadata.isDirectory == true, metadata.isSymbolicLink != true,
                let modified = metadata.contentModificationDate, now.timeIntervalSince(modified) > 60
            else { continue }
            let descriptor = open(directory.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: directory)
            }
            close(descriptor)
        }
    }

    private func acquireLease() throws {
        guard lease == nil else { return }
        let descriptor = open(
            directory.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ServiceError("Couldn’t buffer live transcription audio.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ServiceError("Couldn’t buffer live transcription audio.")
        }
        lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func store(_ packet: Packet) throws {
        let buffer = packet.buffer
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let header = Header(
            start: packet.start, sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount,
            commonFormat: buffer.format.commonFormat.rawValue, interleaved: buffer.format.isInterleaved,
            frames: buffer.frameLength, bufferBytes: buffers.map { Int($0.mDataByteSize) })
        let metadata = try JSONEncoder().encode(header)
        var record = Data()
        var metadataBytes = UInt32(metadata.count).littleEndian
        withUnsafeBytes(of: &metadataBytes) { record.append(contentsOf: $0) }
        record.append(metadata)
        for part in buffers {
            guard let data = part.mData else { throw ServiceError("Live audio buffer is unavailable.") }
            record.append(data.assumingMemoryBound(to: UInt8.self), count: Int(part.mDataByteSize))
        }
        if writer != nil, writeBytes > 0, record.count > chunkBytes - writeBytes {
            try writer?.close()
            writer = nil
            writeChunk += 1
            writeBytes = 0
        }
        if writer == nil {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try acquireLease()
            guard
                FileManager.default.createFile(
                    atPath: chunkURL(writeChunk).path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t buffer live transcription audio.")
            }
            writer = try FileHandle(forWritingTo: chunkURL(writeChunk))
        }
        try writer?.write(contentsOf: record)
        writeBytes += record.count
        diskPackets += 1
        if let span = diskSpan {
            diskSpan = LiveAudioLoss(
                start: min(span.start, packet.start), end: max(span.end, packet.start + packet.duration))
        }
        else {
            diskSpan = LiveAudioLoss(start: packet.start, end: packet.start + packet.duration)
        }
    }

    private func readPacket() throws -> Packet {
        if reader == nil { reader = try FileHandle(forReadingFrom: chunkURL(readChunk)) }
        let prefix = try reader?.read(upToCount: 4) ?? Data()
        if prefix.isEmpty, readChunk < writeChunk {
            try reader?.close()
            reader = nil
            try FileManager.default.removeItem(at: chunkURL(readChunk))
            readChunk += 1
            return try readPacket()
        }
        guard prefix.count == 4 else { throw ServiceError("Buffered live audio is incomplete.") }
        let metadataBytes = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard metadataBytes <= 64 * 1024,
            let metadata = try reader?.read(upToCount: metadataBytes), metadata.count == metadataBytes
        else { throw ServiceError("Buffered live audio is incomplete.") }
        let header = try JSONDecoder().decode(Header.self, from: metadata)
        guard let commonFormat = AVAudioCommonFormat(rawValue: header.commonFormat),
            let format = AVAudioFormat(
                commonFormat: commonFormat, sampleRate: header.sampleRate, channels: header.channels,
                interleaved: header.interleaved),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: header.frames)
        else { throw ServiceError("Buffered live audio has an unsupported format.") }
        buffer.frameLength = header.frames
        let parts = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard parts.count == header.bufferBytes.count else { throw ServiceError("Buffered live audio is incomplete.") }
        for (index, part) in parts.enumerated() {
            let count = header.bufferBytes[index]
            guard count >= 0, count == Int(part.mDataByteSize), let target = part.mData,
                let bytes = try reader?.read(upToCount: count), bytes.count == count
            else { throw ServiceError("Buffered live audio is incomplete.") }
            bytes.copyBytes(to: target.assumingMemoryBound(to: UInt8.self), count: count)
        }
        return Packet(buffer: buffer, start: header.start)
    }

    private func cleanDisk() {
        try? writer?.close()
        try? reader?.close()
        writer = nil
        reader = nil
        try? FileManager.default.removeItem(at: directory)
        try? lease?.close()
        lease = nil
        diskPackets = 0
        diskSpan = nil
        writeChunk = 0
        readChunk = 0
        writeBytes = 0
    }
}
