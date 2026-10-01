import AVFoundation

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
    private var dropped: [(Double, Double)] = []
    static let maximumSeconds = 2.0

    init() {
        let pair = AsyncStream<Packet>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func append(_ buffer: AVAudioPCMBuffer, start: Double) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        guard seconds.isFinite, seconds > 0, start.isFinite, start >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        guard queuedSeconds + seconds <= Self.maximumSeconds,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            if let last = dropped.last, start <= last.1 + 0.01 {
                dropped[dropped.count - 1].1 = max(last.1, start + seconds)
            }
            else {
                dropped.append((start, start + seconds))
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

    func takeDroppedRanges() -> [(Double, Double)] {
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
        lock.lock()
        latestEnds[source] = max(latestEnds[source] ?? 0, start + Double(buffer.frameLength) / buffer.format.sampleRate)
        let queues = consumers.values.compactMap { $0[source] }
        lock.unlock()
        for queue in queues { queue.append(buffer, start: start) }
    }
}
