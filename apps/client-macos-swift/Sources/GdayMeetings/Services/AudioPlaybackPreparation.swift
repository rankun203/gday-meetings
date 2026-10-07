import AVFoundation
import Foundation

struct PreparedPlaybackAudio {
    let url: URL
    let temporary: Bool
}

enum AudioPlaybackPreparation {
    /// Compatibility conversion for transcription/service inputs. Interactive
    /// playback uses OpusFileDecoder/StreamingPlayback and never calls this path.
    /// The caller owns the temporary file and removes it after its consumer finishes.
    static func prepare(_ source: URL) async throws -> PreparedPlaybackAudio {
        guard ["opus", "ogg"].contains(source.pathExtension.lowercased()) else {
            return .init(url: source, temporary: false)
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gday-playback-\(UUID().uuidString).caf")
        do {
            try decodeOpus(source, to: destination)
            try Task.checkCancellation()
            return .init(url: destination, temporary: true)
        }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    static func opusChannels(_ source: URL) throws -> Int { try OggOpusReader(source).channels }
    static func opusMetadata(_ source: URL) async throws -> (channels: Int, duration: Double) {
        let reader = try OggOpusReader(source)
        while try reader.nextAudioPacket() != nil { try Task.checkCancellation() }
        let decoder = try OpusFileDecoder(source)
        return (decoder.channels, Double(decoder.totalFrames) / 48000)
    }

    /// Validate the container before decoding, then use the same libopusfile
    /// timing, pre-skip, gain, and end trimming as interactive playback.
    private static func decodeOpus(_ source: URL, to destination: URL) throws {
        let reader = try OggOpusReader(source)
        while try reader.nextAudioPacket() != nil { try Task.checkCancellation() }
        let decoder = try OpusFileDecoder(source)
        guard decoder.totalFrames > 0,
            let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: UInt32(decoder.channels)),
            let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192),
            let decoded = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 8192)
        else { throw ServiceError("The Opus recording has no playable samples.") }
        let file = try AVAudioFile(forWriting: destination, settings: pcm.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var written: Int64 = 0
        while written < decoder.totalFrames {
            try Task.checkCancellation()
            try decoder.read(into: decoded, frames: decoded.frameCapacity)
            guard decoded.frameLength > 0 else {
                throw ServiceError("The Opus recording ended before its saved duration.")
            }
            output.frameLength = decoded.frameLength
            for channel in 0..<decoder.channels {
                output.floatChannelData![channel].update(
                    from: decoded.floatChannelData![channel], count: Int(decoded.frameLength))
            }
            try file.write(from: output)
            written += Int64(decoded.frameLength)
        }
        guard written == decoder.totalFrames else {
            throw ServiceError("The decoded Opus duration does not match the recording.")
        }
    }

}

private final class OggOpusReader {
    struct Packet {
        let data: Data
        let finalGranule: Int64?
    }
    private(set) var channels = 0
    private let file: FileHandle
    private var packets: [Packet] = []
    private var partial = Data()
    private var serial: UInt32?
    private var sequence: UInt32 = 0
    private(set) var sawEnd = false
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        guard let identification = try nextPacket()?.data, identification.count >= 19,
            identification.prefix(8) == Data("OpusHead".utf8), identification[8] <= 15,
            [1, 2].contains(identification[9]), identification[18] == 0
        else {
            throw ServiceError("Only mono/stereo Ogg Opus mapping family zero is supported.")
        }
        channels = Int(identification[9])
        guard let tags = try nextPacket()?.data, tags.prefix(8) == Data("OpusTags".utf8) else {
            throw ServiceError("The Opus comment header is missing.")
        }
    }
    deinit { try? file.close() }
    func nextAudioPacket() throws -> Packet? { try nextPacket() }
    private func nextPacket() throws -> Packet? {
        while packets.isEmpty {
            if sawEnd { return nil }
            try readPage()
        }
        return packets.removeFirst()
    }
    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw ServiceError("The Ogg recording is truncated.")
            }
            result.append(chunk)
        }
        return result
    }
    private func readPage() throws {
        let header = try readExactly(27)
        guard header.prefix(4) == Data("OggS".utf8), header[4] == 0 else {
            throw ServiceError("Unsupported Ogg audio container.")
        }
        let laces = try readExactly(Int(header[26]))
        let body = try readExactly(laces.reduce(0) { $0 + Int($1) })
        var page = header + laces + body
        let expectedCRC = Self.uint32(header, 22)
        page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        var crc: UInt32 = 0
        for byte in page {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
        }
        guard crc == expectedCRC else { throw ServiceError("The Ogg recording failed its integrity check.") }
        let pageSerial = Self.uint32(header, 14)
        if serial == nil {
            serial = pageSerial
            guard header[5] & 2 != 0 else { throw ServiceError("Missing Ogg stream beginning.") }
        }
        guard serial == pageSerial, Self.uint32(header, 18) == sequence else {
            throw ServiceError("Chained or interrupted Ogg streams are not supported.")
        }
        sequence &+= 1
        guard (header[5] & 1 != 0) == !partial.isEmpty else { throw ServiceError("Invalid continued Ogg packet.") }
        let ended = header[5] & 4 != 0
        var granule: UInt64 = 0
        for index in 0..<8 { granule |= UInt64(header[6 + index]) << (index * 8) }
        var cursor = 0
        for (index, lace) in laces.enumerated() {
            let count = Int(lace)
            partial.append(body[cursor..<(cursor + count)])
            cursor += count
            guard partial.count <= 65_536 else { throw ServiceError("The Ogg packet exceeds the supported size.") }
            if count < 255 {
                let final = ended && index == laces.count - 1 ? Int64(bitPattern: granule) : nil
                packets.append(Packet(data: partial, finalGranule: final))
                partial.removeAll(keepingCapacity: true)
            }
        }
        if ended {
            guard partial.isEmpty else { throw ServiceError("The final Ogg packet is incomplete.") }
            if let trailing = try file.read(upToCount: 1), !trailing.isEmpty {
                throw ServiceError("Chained Ogg streams or trailing bytes are not supported.")
            }
            sawEnd = true
        }
    }
    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
    }
}
