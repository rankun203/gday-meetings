import AVFoundation
import OpusFileBridge

private final class PlaybackRing: @unchecked Sendable {
    let pointer: OpaquePointer
    init(tracks: Int) throws {
        guard let pointer = gday_playback_create(UInt32(tracks), StreamingPlayback.capacity) else {
            throw ServiceError("Playback supports up to 32 audio tracks.")
        }
        self.pointer = pointer
    }
    deinit { gday_playback_destroy(pointer) }
}

/// Owns all decoder/engine operations on one serial queue. The source node only
/// touches the C SPSC ring. All tracks advance under one consumer cursor, so a
/// slow disk inserts shared silence rather than letting one track drift.
final class StreamingPlayback: @unchecked Sendable {
    static let capacity: UInt32 = 16384  // 341 ms at 48 kHz, independent of duration.
    static let blockSize: UInt32 = 4096
    struct Snapshot: Sendable {
        let time: Double
        let playing: Bool
        let ended: Bool
        let revision: UUID
        let error: String?
        let requiresReload: Bool
    }
    var onUpdate: (@Sendable (Snapshot) -> Void)?
    private let queue = DispatchQueue(label: "com.gdaymeetings.playback", qos: .userInitiated)
    private var readers: [any StreamingAudioReading] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var ring: PlaybackRing?
    private var engine: AVAudioEngine?
    private var pitch: AVAudioUnitTimePitch?
    private var timer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var playing = false
    private var closed = false
    private var requiresReload = false
    private var origin: Int64 = 0
    private var produced: Int64 = 0
    private var totalFrames: Int64 = 0
    private var revision = UUID()
    private var drainStarted: TimeInterval?
    private let silent: Bool
    private let manualRendering: Bool

    init(silent: Bool = false, manualRendering: Bool = false) {
        self.silent = silent
        self.manualRendering = manualRendering
    }
    deinit {
        timer?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine?.stop()
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    func prepare(files: [URL]) async throws -> Double {
        try await perform { [self] in
            guard !closed, !files.isEmpty else { throw CancellationError() }
            readers = try files.map { try StreamingAudioReader.open($0) }
            totalFrames = readers.map(\.totalFrames).max() ?? 0
            guard totalFrames > 0 else { throw ServiceError("This recording is empty.") }
            let ring = try PlaybackRing(tracks: readers.count)
            self.ring = ring
            buffers = try readers.map { _ in
                guard
                    let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: Self.blockSize)
                else {
                    throw ServiceError("Cannot allocate playback buffer.")
                }
                return buffer
            }
            let engine = AVAudioEngine()
            let source = AVAudioSourceNode(format: StreamingAudioReader.format) { _, _, frames, audio in
                let buffers = UnsafeMutableAudioBufferListPointer(audio)
                guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else {
                    return kAudio_ParamError
                }
                gday_playback_render(
                    ring.pointer, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self),
                    frames)
                return noErr
            }
            let pitch = AVAudioUnitTimePitch()
            engine.attach(source)
            engine.attach(pitch)
            engine.connect(source, to: pitch, format: StreamingAudioReader.format)
            engine.connect(pitch, to: engine.mainMixerNode, format: StreamingAudioReader.format)
            engine.mainMixerNode.outputVolume = silent ? 0 : 1
            if manualRendering {
                try engine.enableManualRenderingMode(
                    .offline, format: StreamingAudioReader.format, maximumFrameCount: Self.blockSize)
            }
            self.engine = engine
            self.pitch = pitch
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.audioConfigurationChanged()
            }
            try fill()
            return Double(totalFrames) / 48000
        }
    }

    /// A prepared, paused engine also receives route notifications. Invalidate it
    /// for the next explicit Play, but only report an interrupted playback session.
    func audioConfigurationChanged() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            let interrupted = self.playing
            self.requiresReload = true
            self.playing = false
            self.engine?.pause()
            self.timer?.cancel()
            self.timer = nil
            self.publish(
                error: interrupted ? "Audio output changed. Press Play to resume with the current device." : nil)
        }
    }

    func seek(to seconds: Double, revision: UUID) async throws {
        try await perform { [self] in
            guard !closed, let ring, let engine else { throw CancellationError() }
            playing = false
            timer?.cancel()
            timer = nil
            engine.stop()
            engine.reset()
            origin = min(totalFrames, max(0, Int64((seconds * 48000).rounded())))
            produced = origin
            self.revision = revision
            drainStarted = nil
            gday_playback_reset(ring.pointer)
            for reader in readers { try reader.seek(frame: min(origin, reader.totalFrames)) }
            try fill()
            publish()
        }
    }

    func play(rate: Double) async throws {
        try await perform { [self] in
            guard !closed, let engine, let pitch else { throw CancellationError() }
            pitch.rate = Float(rate)
            try fill()
            try engine.start()
            playing = true
            drainStarted = nil
            if !manualRendering {
                // Buffer maintenance is independent of display refresh. Even at 2×,
                // the ring holds 170 ms; a 50 ms refill leaves ample headroom.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 0.05, leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in
                    guard let self, !self.closed, self.playing else { return }
                    do {
                        try self.fill()
                        self.updateEnd()
                        self.publish()
                    }
                    catch { self.fail(error.localizedDescription) }
                }
                self.timer?.cancel()
                self.timer = timer
                timer.resume()
            }
            publish()
        }
    }
    func pause() {
        queue.async { [self] in
            guard !closed else { return }
            playing = false
            engine?.pause()
            timer?.cancel()
            timer = nil
            publish()
        }
    }
    func setRate(_ rate: Double) { queue.async { [self] in pitch?.rate = Float(rate) } }
    func setMuted(_ muted: Set<Int>) {
        queue.async { [self] in
            guard let ring else { return }
            var mask: UInt32 = 0
            for index in readers.indices where !muted.contains(index) { mask |= 1 << UInt32(index) }
            gday_playback_set_audible(ring.pointer, mask)
        }
    }
    func close(removing temporary: [URL] = []) {
        queue.async { [self] in
            closeOnQueue(removing: temporary)
        }
    }
    func shutdown(removing temporary: [URL] = []) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeOnQueue(removing: temporary)
                continuation.resume()
            }
        }
    }
    private func closeOnQueue(removing temporary: [URL]) {
        closed = true
        playing = false
        timer?.cancel()
        timer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        pitch = nil
        readers = []
        buffers = []
        ring = nil
        for url in temporary { try? FileManager.default.removeItem(at: url) }
    }

    private func fill() throws {
        guard let ring else { return }
        while produced < totalFrames, gday_playback_free(ring.pointer) >= Self.blockSize {
            let count = UInt32(min(Int64(Self.blockSize), totalFrames - produced))
            for (index, reader) in readers.enumerated() {
                let buffer = buffers[index]
                let channels = buffer.floatChannelData!
                channels[0].update(repeating: 0, count: Int(Self.blockSize))
                channels[1].update(repeating: 0, count: Int(Self.blockSize))
                if produced < reader.totalFrames { try reader.read(into: buffer, frames: Self.blockSize) }
                // Shorter tracks remain silent on the shared timeline.
                gday_playback_write_track(ring.pointer, UInt32(index), channels[0], channels[1], count)
            }
            gday_playback_commit(ring.pointer, count)
            produced += Int64(count)
        }
    }
    private var position: Double {
        min(
            Double(totalFrames) / 48000,
            Double(origin + Int64(ring.map { gday_playback_consumed($0.pointer) } ?? 0)) / 48000)
    }
    private func updateEnd() {
        guard let ring, produced >= totalFrames, gday_playback_available(ring.pointer) == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if drainStarted == nil { drainStarted = now }
        // Let time-pitch/output latency drain instead of truncating the last block.
        let tail = max(0.1, (pitch?.auAudioUnit.latency ?? 0) + (engine?.outputNode.presentationLatency ?? 0))
        if now - (drainStarted ?? now) >= tail {
            playing = false
            engine?.pause()
            timer?.cancel()
            timer = nil
        }
    }
    private func publish(error: String? = nil) {
        onUpdate?(
            Snapshot(
                time: position, playing: playing,
                ended: !playing && produced >= totalFrames && position >= Double(totalFrames) / 48000,
                revision: revision, error: error, requiresReload: requiresReload))
    }
    private func fail(_ message: String) {
        playing = false
        engine?.pause()
        timer?.cancel()
        timer = nil
        publish(error: message)
    }

    /// Exercises the real engine graph without a device or audible output.
    func renderOffline(frames: UInt32) async throws -> AVAudioPCMBuffer {
        try await perform { [self] in
            guard manualRendering, let engine,
                let result = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: frames)
            else { throw ServiceError("Offline rendering is not enabled.") }
            try fill()
            let status = try engine.renderOffline(frames, to: result)
            guard status == .success else { throw ServiceError("Offline render failed: \(status.rawValue)") }
            return result
        }
    }
}
