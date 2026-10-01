import AVFoundation
import Foundation

/// Opus uses the bundled speech encoder; AAC uses the system codec.
/// The .opus container is RFC 7845 Ogg, never renamed CAF.
/// https://developer.apple.com/documentation/avfaudio/avaudioconverter
/// https://www.rfc-editor.org/rfc/rfc7845.html
/// https://www.xiph.org/ogg/doc/framing.html
/// File conversion runs outside audio delivery and the main actor. PCM originals
/// are owned by the caller and must only be removed after metadata is durably updated.
enum RecordingEncoder {
    static func encode(source: URL, destination: URL, format: RecordingFormat) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw MeetingError.message("Audio encoding cannot replace its source file.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MeetingError.message("The destination audio file already exists.")
        }
        let job = Task.detached(priority: .utility) {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".encode-\(UUID().uuidString).\(format.rawValue)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            switch format {
            case .opus: try encodeOpus(source: source, destination: temporary)
            case .m4a: try encodeM4A(source: source, destination: temporary)
            case .wav: try FileManager.default.copyItem(at: source, to: temporary)
            }
            try Task.checkCancellation()
            // moveItem refuses an existing destination, including one created during encoding.
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    static var supportsOpus: Bool { true }
    static var supportsMP3: Bool { nativeEncoderAvailable(kAudioFormatMPEGLayer3) }
    private static func nativeEncoderAvailable(_ codec: AudioFormatID) -> Bool {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
            let output = AVAudioFormat(settings: [
                AVFormatIDKey: codec, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            ])
        else { return false }
        return AVAudioConverter(from: input, to: output) != nil
    }

    private static func encodeM4A(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw MeetingError.message("Cannot encode an empty recording.") }
        let format = input.processingFormat
        // AVAudioFile/AudioConverter writes the AAC packet table and encoder priming metadata.
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64000 * min(format.channelCount, 2),
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MeetingError.message("Could not allocate audio encoding buffer.")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw MeetingError.message("Audio input ended before all samples were read.")
            }
            try output.write(from: buffer)
        }
        // Lifetime ending closes/finalizes the M4A before the caller renames it.
        withExtendedLifetime(output) {}
    }

    private static func encodeOpus(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0 else { throw MeetingError.message("Cannot encode an empty recording.") }
        let writer = try SpeechOpusWriter(url: destination, format: input.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw MeetingError.message("Could not allocate audio encoding buffer.")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw MeetingError.message("Audio input ended before all samples were read.")
            }
            try writer.append(buffer)
        }
        try writer.finish()
    }

    /// Packet duration comes from the Opus TOC, since Apple's packet descriptions
    /// report zero variable frames. RFC 6716 §3.1; all Ogg granules count 48 kHz frames.
    static func opusPacketFrames(_ packet: Data) throws -> Int {
        guard let toc = packet.first else { throw MeetingError.message("Empty Opus packet.") }
        let samples: Int
        if toc & 0x80 != 0 {
            samples = (48000 << Int((toc >> 3) & 3)) / 400
        }
        else if toc & 0x60 == 0x60 {
            samples = toc & 0x08 != 0 ? 960 : 480
        }
        else {
            let mode = Int((toc >> 3) & 3)
            samples = mode == 3 ? 2880 : (48000 << mode) / 100
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count > 1 else { throw MeetingError.message("Invalid Opus frame-count packet.") }
            count = Int(packet[packet.startIndex + 1] & 0x3f)
        }
        guard count > 0, samples * count <= 5760 else { throw MeetingError.message("Invalid Opus packet duration.") }
        return samples * count
    }
}

final class OggOpusWriter {
    private var handle: FileHandle?
    private let writePage: (FileHandle, Data) throws -> Void
    private let serial = UInt32.random(in: 1...UInt32.max)
    private var sequence: UInt32 = 0
    init(
        destination: URL, channels: UInt8, preSkip: UInt16, inputSampleRate: UInt32,
        writePage: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    ) throws {
        self.writePage = writePage
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MeetingError.message("Could not create encoded recording.") }
        handle = try FileHandle(forWritingTo: destination)
        var identification = Data("OpusHead".utf8)
        identification.append(1)
        identification.append(channels)
        identification.appendLE(preSkip)
        identification.appendLE(inputSampleRate)
        identification.appendLE(UInt16(0))
        identification.append(0)  // gain=0, mapping family 0
        try page(packets: [identification], granule: 0, flags: 2)
        var tags = Data("OpusTags".utf8)
        let vendor = Data("Gday Meetings / libopus".utf8)
        tags.appendLE(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLE(UInt32(0))
        try page(packets: [tags], granule: 0, flags: 0)
    }
    deinit { try? handle?.close() }
    func writeAudio(_ packets: [Data], granule: Int64, final: Bool) throws {
        try page(packets: packets, granule: UInt64(granule), flags: final ? 4 : 0)
    }
    func close() throws {
        if let handle {
            self.handle = nil
            try handle.synchronize()
            try handle.close()
        }
    }
    private func page(packets: [Data], granule: UInt64, flags: UInt8) throws {
        var lacing: [UInt8] = []
        var payload = Data()
        for packet in packets {
            lacing += Array(repeating: 255, count: packet.count / 255)
            lacing.append(UInt8(packet.count % 255))
            payload.append(packet)
        }
        guard lacing.count <= 255 else { throw MeetingError.message("Opus page exceeded its lacing capacity.") }
        var data = Data("OggS".utf8)
        data.append(0)
        data.append(flags)
        data.appendLE(granule)
        data.appendLE(serial)
        data.appendLE(sequence)
        data.appendLE(UInt32(0))
        data.append(UInt8(lacing.count))
        data.append(contentsOf: lacing)
        data.append(payload)
        let checksum = Self.crc(data)
        for offset in 0..<4 { data[22 + offset] = UInt8(truncatingIfNeeded: checksum >> (offset * 8)) }
        guard let handle else { throw MeetingError.message("Encoded recording was already closed.") }
        try writePage(handle, data)
        sequence &+= 1
    }
    static func crc(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
        }
        return crc
    }
}
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
