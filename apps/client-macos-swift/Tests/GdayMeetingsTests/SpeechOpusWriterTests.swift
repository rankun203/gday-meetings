import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct SpeechOpusWriterTests {
    @Test func pageWriteFailureDoesNotPadOrCompleteTheMissingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("partial.opus")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for frame in 0..<48000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.05) * 0.3) }
        var writes = 0
        let writer = try SpeechOpusWriter(url: url, format: format) { handle, data in
            writes += 1
            if writes == 4 {
                // Simulate a disk failure partway through the second audio page.
                try handle.write(contentsOf: data.prefix(16))
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: data)
        }
        #expect(throws: (any Error).self) { try writer.append(buffer) }
        let partial = try Data(contentsOf: url)
        #expect(partial.count > 100)
        #expect(throws: (any Error).self) { try writer.finish() }
        #expect(throws: (any Error).self) { try writer.append(buffer) }
        #expect(throws: (any Error).self) { try writer.finish() }
        #expect(writes == 4)
        #expect(try Data(contentsOf: url) == partial)
        await #expect(throws: (any Error).self) { try await AudioPlaybackPreparation.opusMetadata(url) }
    }

    @Test(arguments: [(48000.0, UInt32(1)), (44100.0, UInt32(2)), (16000.0, UInt32(1))])
    func silenceUsesDTXWithoutShorteningTheTimeline(arguments: (Double, UInt32)) throws {
        let (rate, channels) = arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.opus")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        let writer = try SpeechOpusWriter(url: url, format: format)
        var remaining = Int(rate * 30) + 37
        let total = remaining
        while remaining > 0 {
            buffer.frameLength = UInt32(min(remaining, 1024))
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0 }
            }
            try writer.append(buffer)
            remaining -= Int(buffer.frameLength)
        }
        let liveSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(liveSize > 1000, "Compressed pages must reach disk before Stop.")
        try writer.finish()
        try writer.finish()
        let decoder = try OpusFileDecoder(url)
        #expect(decoder.totalFrames == Int64((Double(total) * 48000 / rate).rounded()))
        #expect(decoder.channels == Int(channels))
        let data = try Data(contentsOf: url)
        // 32 kbps without silence suppression is about 120 KB for 30 seconds.
        // DTX still stores tiny packets so silence does not disappear from playback.
        #expect(data.count < 15000)
        let decoded = try #require(AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 4096))
        var count: Int64 = 0
        repeat {
            try decoder.read(into: decoded, frames: decoded.frameCapacity)
            count += Int64(decoded.frameLength)
        } while decoded.frameLength > 0
        #expect(count == decoder.totalFrames)
    }

    @Test func finalSpeechSamplesSurviveSilenceAndFramePadding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("signal.opus")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 997))
        let total = 48000 * 3 + 73
        let writer = try SpeechOpusWriter(url: url, format: format)
        var position = 0
        while position < total {
            buffer.frameLength = UInt32(min(997, total - position))
            for index in 0..<Int(buffer.frameLength) {
                let frame = position + index
                buffer.floatChannelData![0][index] = frame < 48000 * 2 ? 0 : Float(sin(Double(frame) * 0.05) * 0.3)
            }
            try writer.append(buffer)
            position += Int(buffer.frameLength)
        }
        try writer.finish()
        let decoder = try OpusFileDecoder(url)
        #expect(decoder.totalFrames == total)
        try decoder.seek(frame: Int64(total - 480))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 480))
        try decoder.read(into: output, frames: 480)
        #expect(output.frameLength == 480)
        let energy = (0..<480).reduce(0.0) {
            $0 + Double(output.floatChannelData![0][$1] * output.floatChannelData![0][$1])
        }
        #expect(energy / 480 > 0.01)
    }
}
