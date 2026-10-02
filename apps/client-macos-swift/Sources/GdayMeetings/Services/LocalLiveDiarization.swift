import AVFoundation
import CoreML
@preconcurrency import FluidAudio
import Foundation

struct LiveSpeakerAudioSample: Sendable {
    let speakerID: UUID
    let source: LiveAudioSource
    let generation: UUID
    let start: Double
    let end: Double
    let samples: [Float]
}

/// One actor serializes shared model scratch buffers. Each source owns separate
/// streaming state, resampling history, identity namespace, and bounded PCM.
actor LocalLiveDiarization {
    private let suppliedManager: LocalModelManager?
    private var leaseManager: LocalModelManager?
    init(manager: LocalModelManager? = nil) { suppliedManager = manager }
    private final class Session {
        let source: LiveAudioSource
        let queue = LiveAudioQueue()
        let converter = LivePCMConverter(output: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        var diarizer: Nemotron3Diarizer
        var generation = UUID()
        var speakers: [LiveSpeakerIdentity] = []
        var sequence = 0
        var origin: Double?
        var previousEnd: Double
        var received = 0
        var emitted = 0
        var activity = LiveSpeakerActivityFilter()
        var history: [Float] = []
        var historyStart = 0
        var cleanSlot: Int?
        var cleanStart = 0
        var lastSampleEnds: [Int: Double] = [:]
        var failed = false
        var feed: Task<Void, Never>?
        init(source: LiveAudioSource, boundary: Double, config: Nemotron3Config, models: Nemotron3Models) {
            self.source = source
            previousEnd = boundary
            diarizer = Nemotron3Diarizer(config: config, models: models)
        }
    }
    private let consumer = UUID()
    private var sessions: [Session] = []
    private var lease: LocalModelLease?
    private var sink: LiveAudioSink?
    private var modelID: LocalModelID?
    private var cancelled = false
    private var event: (@Sendable (LiveSpeakerEvent) async -> Void)?
    private var gap: (@Sendable (LiveTranscriptGap) async -> Void)?
    private var failure: (@Sendable (String) async -> Void)?
    private var sample: (@Sendable (LiveSpeakerAudioSample) async -> Void)?

    func start(
        model: LocalModelID, sources: [LiveAudioSource], sink: LiveAudioSink,
        boundaries: [LiveAudioSource: Double],
        event: @escaping @Sendable (LiveSpeakerEvent) async -> Void,
        gap: @escaping @Sendable (LiveTranscriptGap) async -> Void,
        failure: @escaping @Sendable (String) async -> Void,
        sample: @escaping @Sendable (LiveSpeakerAudioSample) async -> Void
    ) async throws {
        guard let preset = model.nemotronPreset, let config = Nemotron3Config.preset(named: preset) else {
            throw MeetingError.message("Choose an installed Nemotron preset for Live Speaker Labels.")
        }
        let manager: LocalModelManager
        if let suppliedManager {
            manager = suppliedManager
        }
        else {
            manager = await LocalModelManager.shared
        }
        let acquired = try await manager.acquire(model)
        guard !cancelled, !Task.isCancelled else {
            await manager.release(acquired)
            throw CancellationError()
        }
        lease = acquired
        leaseManager = manager
        modelID = model
        self.sink = sink
        self.event = event
        self.gap = gap
        self.failure = failure
        self.sample = sample
        do {
            let modelName = URL(fileURLWithPath: config.modelFileName).deletingPathExtension().lastPathComponent
            guard let loaded = acquired.models[modelName] else { throw LocalModelError.unavailable }
            let silence = try Self.floats(
                acquired.directory.appendingPathComponent("learnable_sil_emb.bin"), count: 512)
            let projection =
                config.splitGraph
                ? try Self.floats(acquired.directory.appendingPathComponent("pre_encode_proj_t.bin"), count: 1024 * 512)
                : nil
            let models = try Nemotron3Models(
                config: config, model: loaded, silenceEmbedding: silence,
                preEncodeProjection: projection)
            guard !cancelled, !Task.isCancelled else { throw CancellationError() }
            for source in sources {
                let session = Session(source: source, boundary: boundaries[source] ?? 0, config: config, models: models)
                sessions.append(session)
                session.feed = Task { await self.feed(session) }
            }
            sink.replace(Dictionary(uniqueKeysWithValues: sessions.map { ($0.source, $0.queue) }), consumer: consumer)
        }
        catch {
            await releaseLease()
            throw error
        }
    }

    private static func floats(_ url: URL, count: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count == count * 4 else { throw LocalModelError.invalidFile(url.lastPathComponent) }
        let values = data.withUnsafeBytes { bytes in
            (0..<count).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
        guard values.allSatisfy(\.isFinite) else { throw LocalModelError.invalidFile(url.lastPathComponent) }
        return values
    }

    private func begin(_ session: Session, at origin: Double) async {
        guard let lease, let modelID else { return }
        session.origin = origin
        session.speakers = (0..<8).map {
            .init(
                id: UUID(), source: session.source, generation: session.generation, slot: $0,
                model: modelID.rawValue, revision: lease.revision, activityPolicy: LiveSpeakerActivityFilter.policy)
        }
        await event?(
            .init(
                source: session.source, generation: session.generation, sequence: 0,
                speakers: session.speakers, intervals: [], start: origin, end: origin))
    }

    private func feed(_ session: Session) async {
        for await packet in session.queue.stream {
            session.queue.consumed(packet)
            guard !cancelled, !Task.isCancelled else { break }
            do {
                if LiveAudioInputTimeline.hasGap(from: session.previousEnd, to: packet.start) {
                    try await flush(session)
                    await gap?(
                        .init(
                            source: session.source, start: session.previousEnd, end: packet.start,
                            reason: "Audio was not processed for live speaker labels."))
                    session.diarizer.reset()
                    session.converter.reset()
                    session.generation = UUID()
                    session.origin = nil
                    session.received = 0
                    session.emitted = 0
                    session.sequence = 0
                    session.activity = LiveSpeakerActivityFilter()
                    session.history = []
                    session.historyStart = 0
                    session.cleanSlot = nil
                    session.lastSampleEnds = [:]
                }
                if session.origin == nil { await begin(session, at: packet.start) }
                if let converted = try session.converter.convert(packet.buffer),
                    let channel = converted.floatChannelData?[0]
                {
                    let values = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
                    // Bound each model call independently of capture callback size.
                    for start in stride(from: 0, to: values.count, by: 320) {
                        let block = Array(values[start..<min(values.count, start + 320)])
                        session.history.append(contentsOf: block)
                        session.received += block.count
                        let excess = session.history.count - 45 * 16_000
                        if session.history.count > 46 * 16_000 {
                            session.history.removeFirst(excess)
                            session.historyStart += excess
                        }
                        let results = try autoreleasepool {
                            session.diarizer.appendAudio(block)
                            return try session.diarizer.processBufferedAudio()
                        }
                        try await consume(results, session: session)
                    }
                }
                session.previousEnd = packet.start + packet.duration
            }
            catch {
                session.failed = true
                session.queue.finish()
                await failure?("Live speaker labels stopped for \(session.source.title). Recording continues.")
                break
            }
        }
    }

    private func consume(_ results: [Nemotron3ChunkResult], session: Session) async throws {
        guard let origin = session.origin else { return }
        for result in results {
            guard result.numSpeakers == 8, result.probabilities.count == result.frameCount * 8,
                result.probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
            else {
                throw MeetingError.message("The speaker model returned invalid activity values.")
            }
            let end = origin + Double(session.received) / 16_000
            let start = min(end, origin + Double(session.emitted) * 0.01)
            var intervals: [LiveSpeakerInterval] = []
            var activeStarts = [Double?](repeating: nil, count: 8)
            for frame in 0..<result.frameCount {
                let position = session.emitted + frame
                let time = min(end, origin + Double(position) * 0.01)
                let probabilities = Array(result.probabilities[frame * 8..<frame * 8 + 8])
                let activity = session.activity.accept(probabilities)
                for slot in 0..<8 {
                    if activity[slot] {
                        if activeStarts[slot] == nil { activeStarts[slot] = time }
                    }
                    else if let begin = activeStarts[slot] {
                        if time > begin {
                            intervals.append(.init(speakerID: session.speakers[slot].id, start: begin, end: time))
                        }
                        activeStarts[slot] = nil
                    }
                }
                let confident = probabilities.indices.filter { probabilities[$0] >= 0.7 }
                let clean =
                    confident.count == 1
                        && probabilities.indices.allSatisfy({
                            $0 == confident[0] || probabilities[$0] < 0.2
                        }) ? confident.first : nil
                if clean != session.cleanSlot {
                    session.cleanSlot = clean
                    session.cleanStart = position * 160
                }
                if let slot = clean {
                    let endFrame = min(session.received, (position + 1) * 160)
                    let begin = session.cleanStart
                    let sampleEnd = origin + Double(endFrame) / 16_000
                    if endFrame - begin >= 3 * 16_000,
                        sampleEnd - (session.lastSampleEnds[slot] ?? -.infinity) >= 5,
                        begin >= session.historyStart, endFrame <= session.historyStart + session.history.count
                    {
                        let audio = Array(
                            session.history[(begin - session.historyStart)..<(endFrame - session.historyStart)])
                        await sample?(
                            .init(
                                speakerID: session.speakers[slot].id, source: session.source,
                                generation: session.generation, start: origin + Double(begin) / 16_000,
                                end: sampleEnd, samples: audio))
                        session.lastSampleEnds[slot] = sampleEnd
                        session.cleanStart = endFrame
                    }
                    else if endFrame - begin > 6 * 16_000 {
                        session.cleanStart = endFrame - 3 * 16_000
                    }
                }
            }
            session.emitted += result.frameCount
            let emittedEnd = min(end, origin + Double(session.emitted) * 0.01)
            for slot in 0..<8 {
                if let begin = activeStarts[slot], emittedEnd > begin {
                    intervals.append(.init(speakerID: session.speakers[slot].id, start: begin, end: emittedEnd))
                }
            }
            session.sequence += 1
            await event?(
                .init(
                    source: session.source, generation: session.generation, sequence: session.sequence,
                    speakers: session.speakers, intervals: intervals, start: start, end: emittedEnd))
        }
    }

    private func flush(_ session: Session) async throws {
        guard let origin = session.origin else { return }
        try await consume(session.diarizer.finishStream(), session: session)
        session.sequence += 1
        let end = origin + Double(session.received) / 16_000
        await event?(
            .init(
                source: session.source, generation: session.generation, sequence: session.sequence,
                speakers: session.speakers, intervals: [], start: end, end: end, final: true))
    }

    func finish() async -> Bool {
        sink?.replace([:], consumer: consumer)
        let pending = sessions
        for session in pending { session.queue.finish() }
        for session in pending { await session.feed?.value }
        var complete = !cancelled && !pending.isEmpty
        for session in pending {
            if !cancelled && !session.failed {
                do { try await flush(session) }
                catch { session.failed = true }
            }
            for range in session.queue.takeDroppedRanges() {
                complete = false
                await gap?(
                    .init(
                        source: session.source, start: range.0, end: range.1,
                        reason: "Live speaker labels couldn’t keep up."))
            }
            if session.failed {
                complete = false
                let end = sink?.positions()[session.source] ?? session.previousEnd
                if end > session.previousEnd {
                    await gap?(
                        .init(
                            source: session.source, start: session.previousEnd, end: end,
                            reason: "Live speaker labels stopped before this audio was processed."))
                }
            }
        }
        sessions.removeAll()
        await releaseLease()
        return complete
    }

    func cancel() async {
        cancelled = true
        sink?.replace([:], consumer: consumer)
        for session in sessions {
            session.queue.finish()
            session.feed?.cancel()
        }
        for session in sessions { await session.feed?.value }
        sessions.removeAll()
        await releaseLease()
    }

    private func releaseLease() async {
        guard let lease else { return }
        self.lease = nil
        await leaseManager?.release(lease)
        leaseManager = nil
    }
}
