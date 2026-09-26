import AVFoundation
import AudioToolbox

/// A silent interval in one track, in seconds from the recording epoch.
struct RecordingGap: Codable, Equatable {
    var start: Double
    var duration: Double
}
struct AudioTrackProfile: Codable, Equatable {
    var filename: String
    var sampleRate: Double
    var channels: UInt32
    var voiceProcessed: Bool
    var gaps: [RecordingGap] = []
}
extension AudioTrackProfile {
    // Recordings saved before gap tracking have no `gaps` key.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filename = try values.decode(String.self, forKey: .filename)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        channels = try values.decode(UInt32.self, forKey: .channels)
        voiceProcessed = try values.decode(Bool.self, forKey: .voiceProcessed)
        gaps = try values.decodeIfPresent([RecordingGap].self, forKey: .gaps) ?? []
    }
}
/// The session's microphone voice-processing choice; `automatic` follows the output route.
enum VoiceProcessingPolicy: String, Codable {
    case automatic, on, off
}
/// The effective device and format a source switched to during recording.
struct RecordingRouteChange: Codable, Equatable {
    /// Seconds from the recording epoch.
    var time: Double
    /// "microphone" or "system".
    var source: String
    var device: String?
    var sampleRate: Double
    var channels: UInt32
    var voiceProcessed: Bool
    /// Why the source changed, from `Reason`; `nil` for the initial route and older recordings.
    /// Stored as text so a reason added later never makes a saved library unreadable.
    var reason: String? = nil

    enum Reason: String {
        /// The default device changed, or the device or format changed underneath the source.
        case route
        /// Voice Processing was switched on or off during recording.
        case voiceProcessingSwitched
        /// Echo detection turned voice processing on.
        case echoDetected
        /// Voice processing could not be enabled; the source records unprocessed.
        case voiceProcessingUnavailable
        /// The selected microphone is not connected; the source records from the default input.
        case selectedMicrophoneUnavailable
        /// The selected microphone is connected again and in use.
        case selectedMicrophoneReturned
    }
}
struct RecordingProfile: Codable, Equatable {
    /// Voice processing when recording started; later changes appear in `routeChanges`.
    var microphoneVoiceProcessing: Bool
    var tracks: [AudioTrackProfile]
    var timeline = "Host clock; missing intervals padded with silence"
    /// `nil` for recordings saved before the policy was persisted.
    var voiceProcessingPolicy: VoiceProcessingPolicy? = nil
    var routeChanges: [RecordingRouteChange] = []
}
extension RecordingProfile {
    // Older recordings omit the route history and policy keys.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        microphoneVoiceProcessing = try values.decode(Bool.self, forKey: .microphoneVoiceProcessing)
        tracks = try values.decode([AudioTrackProfile].self, forKey: .tracks)
        timeline =
            try values.decodeIfPresent(String.self, forKey: .timeline)
            ?? "Host clock; missing intervals padded with silence"
        voiceProcessingPolicy = try values.decodeIfPresent(VoiceProcessingPolicy.self, forKey: .voiceProcessingPolicy)
        routeChanges = try values.decodeIfPresent([RecordingRouteChange].self, forKey: .routeChanges) ?? []
    }
}

/// Apple documents ExtAudioFileWriteAsync as a bounded internal ring-buffer handoff;
/// warm it outside callbacks and dispose to flush. No filesystem work occurs in append.
/// https://developer.apple.com/documentation/audiotoolbox/extaudiofilewriteasync(_:_:_:)
/// AVAudioEngine regular taps are not realtime render blocks (WWDC19, 510).
///
/// The track format is fixed for the whole file so a device change never reinterprets samples.
/// Incoming Float32 buffers in another layout are first mapped to the track's channel count at their
/// own rate, then resampled/interleaved by AVAudioConverter. Channel mapping for N inputs to M outputs:
/// - M >= N: output channel c copies input channel c mod N (mono to stereo duplicates).
/// - M < N: output channel c averages the input channels k where k mod M == c (N to mono averages all).
final class TimedAudioWriter {
    private var file: ExtAudioFileRef?
    /// Fixed for the whole file; every appended sample is converted to it.
    private let format: AVAudioFormat
    private let silence: AVAudioPCMBuffer
    private let lock = NSLock()
    private var framesWritten: Int64 = 0
    private var sourceFrames: Int64 = 0
    private let epoch: TimeInterval
    private let filename: String
    private let voiceProcessed: Bool
    private var failure: Error?
    private var finished = false
    private let alignedAudio: ((AVAudioPCMBuffer, Double) -> Void)?
    /// Silence runs in track frames; contiguous padding extends the last run.
    private var gapRuns: [(start: Int64, frames: Int64)] = []
    private var converter: AVAudioConverter?
    private var converterNeedsReset = false
    private static let ioBufferBytes: UInt32 = 512 * 1024
    /// Gaps shorter than this are clock jitter or buffer scheduling, not outages worth reporting.
    private static let reportedGapSeconds = 0.1

    var capturedFrames: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sourceFrames
    }
    /// Includes every silent interval of at least 0.1 s, including startup skew at frame 0.
    var profile: AudioTrackProfile {
        lock.lock()
        defer { lock.unlock() }
        let rate = format.sampleRate
        let minimum = Int64(rate * Self.reportedGapSeconds)
        return AudioTrackProfile(
            filename: filename, sampleRate: rate, channels: format.channelCount, voiceProcessed: voiceProcessed,
            gaps: gapRuns.filter { $0.frames >= minimum }.map {
                RecordingGap(start: Double($0.start) / rate, duration: Double($0.frames) / rate)
            })
    }

    init(
        url: URL, format: AVAudioFormat, epoch: TimeInterval, voiceProcessed: Bool = false,
        alignedAudio: ((AVAudioPCMBuffer, Double) -> Void)? = nil
    ) throws {
        self.alignedAudio = alignedAudio
        self.format = format
        self.epoch = epoch
        self.voiceProcessed = voiceProcessed
        filename = url.lastPathComponent
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw MeetingError.message("Could not allocate audio silence buffer.")
        }
        self.silence = silence
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        // Integer PCM has predictable size and interoperates with the transcription service.
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * format.channelCount, mFramesPerPacket: 1, mBytesPerFrame: 2 * format.channelCount,
            mChannelsPerFrame: format.channelCount, mBitsPerChannel: 16, mReserved: 0)
        try Self.check(
            ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileWAVEType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &file))
        do {
            var client = format.streamDescription.pointee
            try Self.check(
                ExtAudioFileSetProperty(
                    file!, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
            // The async ring buffer scales with this size. An overflow silently discards buffered audio, so a
            // larger ring gives silence padding after an outage headroom (default 64 KiB holds about 1 s).
            var ioBufferBytes = Self.ioBufferBytes
            try Self.check(
                ExtAudioFileSetProperty(
                    file!, kExtAudioFileProperty_IOBufferSizeBytes, UInt32(MemoryLayout<UInt32>.size),
                    &ioBufferBytes))
            try Self.check(ExtAudioFileWriteAsync(file!, 0, nil))
        }
        catch {
            if let file { ExtAudioFileDispose(file) }
            file = nil
            throw error
        }
    }
    deinit { if let file { ExtAudioFileDispose(file) } }

    /// Host-time anchoring pads startup skew and dropped intervals instead of collapsing time.
    /// Buffers in another format are converted to the track format before placement.
    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        // Late tap callbacks after stop are expected and must not surface as errors.
        guard !finished else { return }
        if let failure { throw failure }
        guard let file else { return }
        do {
            let target = try Self.targetFrame(hostSeconds: hostSeconds, epoch: epoch, sampleRate: format.sampleRate)
            // Pad first so a converter reset after an outage applies to this buffer.
            try padLocked(file, through: target)
            let samples = buffer.format == format ? buffer : try convertLocked(buffer)
            guard samples.frameLength > 0 else { return }
            let overlap = max(0, framesWritten - target)
            if overlap > tolerance {
                // Drop overlapping source frames; copying here is safe in a regular non-RT tap.
                let skipped = min(Int64(samples.frameLength), overlap)
                guard skipped < samples.frameLength else { return }
                let count = samples.frameLength - AVAudioFrameCount(skipped)
                guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    throw MeetingError.message("Could not allocate aligned audio buffer.")
                }
                trimmed.frameLength = count
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                for (source, destination) in zip(
                    UnsafeMutableAudioBufferListPointer(samples.mutableAudioBufferList),
                    UnsafeMutableAudioBufferListPointer(trimmed.mutableAudioBufferList))
                {
                    if let src = source.mData, let dst = destination.mData {
                        memcpy(dst, src.advanced(by: Int(skipped) * bytesPerFrame), Int(count) * bytesPerFrame)
                    }
                }
                try Self.check(ExtAudioFileWriteAsync(file, count, trimmed.audioBufferList))
                alignedAudio?(trimmed, Double(framesWritten) / format.sampleRate)
                framesWritten += Int64(count)
                sourceFrames += Int64(count)
            }
            else {
                try Self.check(ExtAudioFileWriteAsync(file, samples.frameLength, samples.audioBufferList))
                alignedAudio?(samples, Double(framesWritten) / format.sampleRate)
                framesWritten += Int64(samples.frameLength)
                sourceFrames += Int64(samples.frameLength)
            }
        }
        catch {
            failure = error
            throw error
        }
    }
    /// Keeps the file at pace with the host clock while a source reconnects. Calling this about once
    /// per second bounds each write; a later overlapping append is trimmed against the padding.
    func padSilence(throughHostSeconds: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if let failure { throw failure }
        guard let file else { return }
        do {
            let target = try Self.targetFrame(
                hostSeconds: throughHostSeconds, epoch: epoch, sampleRate: format.sampleRate)
            try padLocked(file, through: target)
        }
        catch {
            failure = error
            throw error
        }
    }
    /// Pads a trailing outage when the source never returned, then flushes the file.
    func finish(throughHostSeconds: TimeInterval? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if !finished, failure == nil, let file, let throughHostSeconds {
            do {
                let target = try Self.targetFrame(
                    hostSeconds: throughHostSeconds, epoch: epoch, sampleRate: format.sampleRate)
                try padLocked(file, through: target)
            }
            catch { failure = error }
        }
        finished = true
        converter = nil
        var disposal: OSStatus = noErr
        if let file {
            disposal = ExtAudioFileDispose(file)
            self.file = nil
        }
        if let failure { throw failure }
        try Self.check(disposal)
    }

    static func targetFrame(hostSeconds: TimeInterval, epoch: TimeInterval, sampleRate: Double) throws -> Int64 {
        let value = (hostSeconds - epoch) * sampleRate
        guard value.isFinite, sampleRate > 0, abs(value) < Double(Int64.max) else {
            throw MeetingError.message("Audio capture returned an invalid timestamp.")
        }
        return max(0, Int64(value.rounded()))
    }

    /// Sub-millisecond clock quantisation is normal; do not insert jitter-sized holes.
    private var tolerance: Int64 { Int64(format.sampleRate * 0.002) }

    /// Writes silence in fixed chunks from the preallocated buffer, so memory does not grow with
    /// outage length. Must be called with `lock` held.
    private func padLocked(_ file: ExtAudioFileRef, through target: Int64) throws {
        var gap = target - framesWritten
        guard gap > tolerance else { return }
        if let last = gapRuns.last, last.start + last.frames == framesWritten {
            // Nothing was written since the previous padding: one outage, one gap.
            gapRuns[gapRuns.count - 1].frames += gap
        }
        else {
            gapRuns.append((framesWritten, gap))
        }
        var burst: Int64 = 0
        while gap > 0 {
            let count = UInt32(min(gap, Int64(silence.frameCapacity)))
            // Beyond one second in a single call, yield so the background writer drains the ring;
            // periodic padSilence calls keep normal outages below this threshold.
            if burst >= Int64(format.sampleRate) { usleep(1000) }
            try Self.check(ExtAudioFileWriteAsync(file, count, silence.audioBufferList))
            framesWritten += Int64(count)
            burst += Int64(count)
            gap -= Int64(count)
        }
        // Resampler history from before the outage must not blend into the resumed audio.
        converterNeedsReset = true
    }

    /// Maps channels at the source rate, then converts rate and layout into the track format.
    /// Must be called with `lock` held.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let input = buffer.format
        guard input.commonFormat == .pcmFormatFloat32, let source = buffer.floatChannelData, input.sampleRate > 0
        else {
            throw MeetingError.message("Audio capture returned samples in an unsupported format (\(input)).")
        }
        // Track channel count at the source rate, deinterleaved; the converter then changes only rate/layout.
        let mappedFormat: AVAudioFormat? =
            if let layout = format.channelLayout {
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, interleaved: false,
                    channelLayout: layout)
            }
            else {
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: format.channelCount,
                    interleaved: false)
            }
        guard let mappedFormat,
            let mapped = AVAudioPCMBuffer(pcmFormat: mappedFormat, frameCapacity: buffer.frameLength),
            let destination = mapped.floatChannelData
        else {
            throw MeetingError.message("Could not allocate converted audio buffer.")
        }
        mapped.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let inputs = Int(input.channelCount)
        let outputs = Int(format.channelCount)
        // floatChannelData[c][frame * stride] addresses both interleaved and deinterleaved buffers.
        let stride = buffer.stride
        if outputs >= inputs {
            for channel in 0..<outputs {
                let from = source[channel % inputs]
                let to = destination[channel]
                for frame in 0..<frames { to[frame] = from[frame * stride] }
            }
        }
        else {
            for channel in 0..<outputs {
                let to = destination[channel]
                let group = Swift.stride(from: channel, to: inputs, by: outputs).map { source[$0] }
                let scale = 1 / Float(group.count)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for from in group { sum += from[frame * stride] }
                    to[frame] = sum * scale
                }
            }
        }
        if mappedFormat == format { return mapped }

        // One converter per source format; a new device format gets fresh resampler state.
        if converter?.inputFormat != mappedFormat {
            converter = AVAudioConverter(from: mappedFormat, to: format)
            converterNeedsReset = false
        }
        guard let converter else {
            throw MeetingError.message("Could not convert audio from \(input) to \(format).")
        }
        if converterNeedsReset {
            converter.reset()
            converterNeedsReset = false
        }
        let ratio = format.sampleRate / mappedFormat.sampleRate
        // Slack covers resampler output that was held back from earlier buffers.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw MeetingError.message("Could not allocate converted audio buffer.")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            // `noDataNow` keeps resampler state for the next buffer, unlike `endOfStream`.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mapped
        }
        if status == .error {
            throw MeetingError.message(
                "Could not convert audio from \(input) to \(format): \(conversionError?.localizedDescription ?? "unknown error")."
            )
        }
        return output
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw MeetingError.message(
                "Audio recording failed (Core Audio \(status)). The disk may be full or unable to keep up; the partial recording is retained."
            )
        }
    }
}
