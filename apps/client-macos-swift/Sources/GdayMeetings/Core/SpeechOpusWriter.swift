import AVFoundation
import OpusFileBridge

/// One continuous encoder per track, called only on its owning writer queue.
/// PCM memory and the pending Ogg page are bounded independently of recording length.
final class SpeechOpusWriter {
    private let encoder: OpaquePointer
    private let format: AVAudioFormat
    private let channels: Int
    private let preSkip: Int64
    private let muxer: OggOpusWriter
    private let converter: AVAudioConverter?
    private let inputChunk: AVAudioPCMBuffer?
    private let converted: AVAudioPCMBuffer?
    private var samples: [Float]
    private var packet = [UInt8](repeating: 0, count: 4000)
    private var pendingFrames = 0
    private var pendingPackets: [Data] = []
    private var inputFrames: Int64 = 0
    private var encodedFrames: Int64 = 0
    private var finished = false
    private var failure: Error?

    init(
        url: URL, format: AVAudioFormat,
        writePage: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    ) throws {
        guard format.commonFormat == .pcmFormatFloat32, format.sampleRate.isFinite, format.sampleRate > 0,
            format.channelCount == 1 || format.channelCount == 2
        else { throw MeetingError.message("Opus recording requires mono or stereo audio.") }
        self.format = format
        channels = Int(format.channelCount)
        samples = [Float](repeating: 0, count: 960 * channels)
        if format.sampleRate != 48000 {
            guard let target = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: format.channelCount),
                let converter = AVAudioConverter(from: format, to: target),
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
                let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
            else { throw MeetingError.message("Could not prepare Opus sample rate conversion.") }
            // Normal priming compensates resampler delay; .none loses tail samples
            // when the final Opus granule trims the result to the input duration.
            converter.primeMethod = .normal
            self.converter = converter
            inputChunk = input
            converted = output
        }
        else {
            converter = nil
            inputChunk = nil
            converted = nil
        }
        var error: Int32 = 0
        guard let encoder = gday_opus_encoder_create(Int32(channels), &error) else {
            throw Self.codecError(error)
        }
        do {
            let lookahead = gday_opus_encoder_lookahead(encoder)
            guard lookahead >= 0, lookahead <= UInt16.max else { throw Self.codecError(lookahead) }
            preSkip = Int64(lookahead)
            muxer = try OggOpusWriter(
                destination: url, channels: UInt8(channels), preSkip: UInt16(lookahead),
                inputSampleRate: UInt32(min(Double(UInt32.max), format.sampleRate.rounded())), writePage: writePage)
        }
        catch {
            gday_opus_encoder_destroy(encoder)
            throw error
        }
        self.encoder = encoder
    }

    deinit { gday_opus_encoder_destroy(encoder) }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if let failure { throw failure }
        guard !finished else { throw MeetingError.message("The Opus recording is already closed.") }
        guard buffer.format == format else { throw MeetingError.message("The Opus input format changed.") }
        guard buffer.frameLength > 0 else { return }
        do {
            inputFrames += Int64(buffer.frameLength)
            if converter != nil {
                try convert(buffer)
            }
            else {
                try consume(buffer)
            }
        }
        catch {
            // A failed write may have emitted only part of a page. Do not retry
            // encoding or pad the rest of this buffer into a false complete file.
            failure = error
            try? muxer.close()
            throw error
        }
    }

    func finish() throws {
        if let failure { throw failure }
        guard !finished else { return }
        finished = true
        defer { try? muxer.close() }
        do {
            if converter != nil { try convert(nil) }
            // Encode through the codec lookahead so the last real samples are retained.
            // The final granule trims frame padding and resampling rounding exactly.
            let finalGranule = Int64((Double(inputFrames) * 48000 / format.sampleRate).rounded()) + preSkip
            if pendingFrames > 0 {
                for index in (pendingFrames * channels)..<samples.count { samples[index] = 0 }
                try encodeFrame()
            }
            while encodedFrames < finalGranule || pendingPackets.isEmpty {
                for index in samples.indices { samples[index] = 0 }
                try encodeFrame()
            }
            try muxer.writeAudio(pendingPackets, granule: finalGranule, final: true)
            pendingPackets.removeAll()
            try muxer.close()
        }
        catch {
            failure = error
            throw error
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer?) throws {
        guard let converter, let inputChunk, let converted else { return }
        var offset: AVAudioFrameCount = 0
        while true {
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { requested, state in
                guard let buffer else {
                    state.pointee = .endOfStream
                    return nil
                }
                guard offset < buffer.frameLength else {
                    state.pointee = .noDataNow
                    return nil
                }
                let count = min(requested, inputChunk.frameCapacity, buffer.frameLength - offset)
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(inputChunk.mutableAudioBufferList)
                let stride = Int(self.format.streamDescription.pointee.mBytesPerFrame)
                inputChunk.frameLength = count
                for index in source.indices {
                    memcpy(
                        destination[index].mData!, source[index].mData!.advanced(by: Int(offset) * stride),
                        Int(count) * stride)
                }
                offset += count
                state.pointee = .haveData
                return inputChunk
            }
            if let error { throw error }
            guard status != .error else { throw MeetingError.message("Could not resample Opus audio.") }
            try consume(converted)
            if status == .endOfStream { return }
            if status == .inputRanDry, buffer != nil, offset == buffer!.frameLength { return }
            guard status == .haveData || converted.frameLength > 0 else {
                throw MeetingError.message("Opus sample rate conversion stopped before finishing.")
            }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard let source = buffer.floatChannelData else { throw MeetingError.message("Opus input has no samples.") }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            let count = min(960 - pendingFrames, Int(buffer.frameLength) - offset)
            for frame in 0..<count {
                for channel in 0..<channels {
                    samples[(pendingFrames + frame) * channels + channel] =
                        buffer.format.isInterleaved
                        ? source[0][(offset + frame) * channels + channel] : source[channel][offset + frame]
                }
            }
            offset += count
            pendingFrames += count
            if pendingFrames == 960 { try encodeFrame() }
        }
    }

    private func encodeFrame() throws {
        let count = samples.withUnsafeBufferPointer { input in
            packet.withUnsafeMutableBufferPointer { output in
                gday_opus_encoder_encode(encoder, input.baseAddress, 960, output.baseAddress, Int32(output.count))
            }
        }
        guard count > 0 else { throw Self.codecError(count) }
        // Retain one page until the next packet, so Stop can mark and trim EOS.
        if pendingPackets.count == 20 {
            try muxer.writeAudio(pendingPackets, granule: encodedFrames, final: false)
            pendingPackets.removeAll(keepingCapacity: true)
        }
        // Keep DTX packets in the container: silence still occupies timeline space.
        pendingPackets.append(Data(packet.prefix(Int(count))))
        encodedFrames += 960
        pendingFrames = 0
    }

    private static func codecError(_ code: Int32) -> MeetingError {
        MeetingError.message("Could not encode Opus audio: \(String(cString: gday_opus_encoder_error(code))).")
    }
}
