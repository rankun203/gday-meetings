import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct RecordingEncoderTests {
    private func fixture(directory: URL, sampleRate: Double, channels: UInt32, frames: Int) throws -> URL {
        let url = directory.appendingPathComponent("source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                data[channel][frame] = Float(
                    sin(Double(frame) * 2 * .pi * Double(330 + channel * 220) / sampleRate) * 0.3)
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }
    @Test(arguments: [(48000.0, UInt32(1), 24101), (44100.0, UInt32(2), 22073), (48000.0, UInt32(1), 100)])
    func opusRoundTripPreservesDurationChannelsAndSignal(arguments: (Double, UInt32, Int)) async throws {
        let (sampleRate, channels, frames) = arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(directory: root, sampleRate: sampleRate, channels: channels, frames: frames)
        let destination = root.appendingPathComponent("recording.opus")
        try await RecordingEncoder.encode(source: source, destination: destination, format: .opus)
        let data = try Data(contentsOf: destination)
        #expect(data.prefix(4) == Data("OggS".utf8))
        #expect(data.range(of: Data("OpusHead".utf8)) != nil)
        let prepared = try await AudioPlaybackPreparation.prepare(destination)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let decoded = try AVAudioFile(forReading: prepared.url)
        #expect(decoded.processingFormat.channelCount == channels)
        #expect(abs(decoded.length - Int64((Double(frames) * 48000 / sampleRate).rounded())) <= 1)
        let samples = try #require(
            AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: UInt32(decoded.length)))
        try decoded.read(into: samples)
        let values = try #require(samples.floatChannelData)
        for channel in 0..<Int(channels) {
            let energy = (0..<Int(samples.frameLength)).reduce(0.0) {
                $0 + Double(values[channel][$1] * values[channel][$1])
            }
            if frames > 1000 { #expect(energy / Double(samples.frameLength) > 0.01) }
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    @Test func m4aEncodingAndExistingDestinationProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(directory: root, sampleRate: 48000, channels: 2, frames: 48000)
        let destination = root.appendingPathComponent("recording.m4a")
        try await RecordingEncoder.encode(source: source, destination: destination, format: .m4a)
        let output = try AVAudioFile(forReading: destination)
        #expect(output.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(output.fileFormat.channelCount == 2)
        let before = try Data(contentsOf: destination)
        await #expect(throws: (any Error).self) {
            try await RecordingEncoder.encode(source: source, destination: destination, format: .m4a)
        }
        #expect(try Data(contentsOf: destination) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".encode-") })
    }
    @Test func tocDurationAndInvalidPackets() throws {
        #expect(try RecordingEncoder.opusPacketFrames(Data([0xf8])) == 960)
        #expect(try RecordingEncoder.opusPacketFrames(Data([0xf9])) == 1920)
        #expect(throws: (any Error).self) { try RecordingEncoder.opusPacketFrames(Data()) }
        #expect(throws: (any Error).self) { try RecordingEncoder.opusPacketFrames(Data([0xfb, 0])) }
    }
}
