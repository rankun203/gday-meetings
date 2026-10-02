import AVFoundation

/// A bounded loss record. Inexact records cover several losses and may contain
/// successfully processed intervals; callers must preserve that distinction.
struct LiveAudioLoss: Equatable, Sendable {
    var start: Double
    var end: Double
    var isExact = true
}

/// Called only from the regular microphone tap / system consumer, never from the real-time IOProc.
/// Queue ownership ends on dequeue. At most two seconds of PCM await conversion, regardless of callback size.
final class LiveAudioQueue: @unchecked Sendable {
    struct Packet: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let start: Double
        var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
    }
    let stream: AsyncStream<Packet>
    private let continuation: AsyncStream<Packet>.Continuation
    private let lock = NSLock()
    private var queuedSeconds = 0.0
    private var ended = false
    private var dropped: [LiveAudioLoss] = []
    static let maximumSeconds = 2.0
    static let maximumDroppedRanges = 64

    init() {
        let pair = AsyncStream<Packet>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func append(_ buffer: AVAudioPCMBuffer, start: Double) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        guard seconds.isFinite, seconds > 0, start.isFinite, start >= 0, (start + seconds).isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        guard queuedSeconds + seconds <= Self.maximumSeconds,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            if let last = dropped.last, start <= last.end + 0.01 {
                dropped[dropped.count - 1] = LiveAudioLoss(
                    start: min(last.start, start), end: max(last.end, start + seconds),
                    isExact: last.isExact && start <= last.end + 0.000_001)
            }
            else if dropped.count < Self.maximumDroppedRanges {
                dropped.append(LiveAudioLoss(start: start, end: start + seconds))
            }
            else if let last = dropped.last {
                dropped[dropped.count - 1] = LiveAudioLoss(
                    start: min(last.start, start), end: max(last.end, start + seconds), isExact: false)
            }
            return
        }
        copy.frameLength = buffer.frameLength
        for (from, to) in zip(
            UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
            UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList))
        {
            if let src = from.mData, let dst = to.mData { memcpy(dst, src, Int(from.mDataByteSize)) }
        }
        queuedSeconds += seconds
        continuation.yield(Packet(buffer: copy, start: start))
    }

    func consumed(_ packet: Packet) {
        lock.lock()
        queuedSeconds = max(0, queuedSeconds - packet.duration)
        lock.unlock()
    }

    func takeDroppedRanges() -> [LiveAudioLoss] {
        lock.lock()
        defer { lock.unlock() }
        let result = dropped
        dropped = []
        return result
    }

    func finish() {
        lock.lock()
        ended = true
        continuation.finish()
        lock.unlock()
    }
}

/// One stable fan-out is installed before capture starts. Downloads and toggle changes only replace its destinations.
final class LiveAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [UUID: [LiveAudioSource: LiveAudioQueue]] = [:]
    private let transcriptionConsumer = UUID()
    private var latestEnds: [LiveAudioSource: Double] = [:]
    func positions() -> [LiveAudioSource: Double] {
        lock.lock()
        defer { lock.unlock() }
        return latestEnds
    }
    func replace(_ queues: [LiveAudioSource: LiveAudioQueue]) {
        replace(queues, consumer: transcriptionConsumer)
    }
    func replace(_ queues: [LiveAudioSource: LiveAudioQueue], consumer: UUID) {
        lock.lock()
        if queues.isEmpty {
            consumers.removeValue(forKey: consumer)
        }
        else {
            consumers[consumer] = queues
        }
        lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer, start: Double, source: LiveAudioSource) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, (start + duration).isFinite else { return }
        lock.lock()
        latestEnds[source] = max(latestEnds[source] ?? 0, start + duration)
        let queues = consumers.values.compactMap { $0[source] }
        lock.unlock()
        for queue in queues { queue.append(buffer, start: start) }
    }
}
