import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct TimedAudioResamplerContinuityTests {
    private func format(_ rate: Double) throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }
    private func buffer(_ format: AVAudioFormat, frames: UInt32, value: Float = 0.4) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    @Test(arguments: [
        (48000.0, 24000.0, UInt32(4800)), (44100, 48000, UInt32(441)), (48000, 24000, UInt32(48)),
        (48000, 44100, UInt32(1000)), (44100, 48000, UInt32(100)),
        (48000, 16000, UInt32(48)), (24000, 48000, UInt32(24)),
    ])
    func continuousInputNeverTurnsConverterLatencyIntoMissingAudio(_ rates: (Double, Double, UInt32)) throws {
        let (inputRate, outputRate, frames) = rates
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try format(inputRate)
        let track = try format(outputRate)
        var ranges: [(Double, Double)] = []
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0) { buffer, start in
            ranges.append((start, start + Double(buffer.frameLength) / outputRate))
        }
        let count = Int(inputRate * 2 / Double(frames))
        for index in 0..<count {
            try writer.append(
                try buffer(input, frames: frames), hostSeconds: Double(index) * Double(frames) / inputRate)
            // Periodic reconnect padding behind accepted input must not flush/reset a healthy converter.
            try writer.padSilence(throughHostSeconds: max(0, Double(index) * Double(frames) / inputRate - 0.5))
        }
        try writer.finish()
        let samples = try read(url)
        #expect(samples.count == Int(outputRate * 2))
        #expect(writer.profile.gaps.isEmpty)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { abs($0.1 - $1.0) < 1 / outputRate })
        #expect(abs((ranges.last?.1 ?? 0) - 2) < 1 / outputRate)
        // Detect the periodic15ms holes even though they are below gap-report threshold.
        #expect(samples[Int(outputRate / 10)..<Int(outputRate * 1.9)].allSatisfy { abs($0) > 0.2 })
    }
    @Test func duplicateInputNeverContaminatesConverterAndFormatEpochsDrain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try format(48000)
        let track = try format(24000)
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0)
        try writer.append(try buffer(input, frames: 4800), hostSeconds: 0)
        try writer.append(try buffer(input, frames: 4800, value: -0.9), hostSeconds: 0)
        // Partially overlapping packet has poison only in the discarded prefix.
        let overlapping = try buffer(input, frames: 4800)
        for index in 0..<2400 { overlapping.floatChannelData![0][index] = -0.9 }
        try writer.append(overlapping, hostSeconds: 0.05)
        try writer.append(try buffer(track, frames: 2400), hostSeconds: 0.15)
        try writer.append(try buffer(input, frames: 4800), hostSeconds: 0.25)
        try writer.finish()
        let samples = try read(url)
        #expect(samples.count == 8400)
        #expect(samples[100..<8300].allSatisfy { $0 > 0.2 })
        #expect(writer.profile.gaps.isEmpty)
    }
    @Test func actualGapDrainsOldTailAndRejectsLateAudioBeforeResume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try format(48000)
        let track = try format(24000)
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0)
        try writer.append(try buffer(input, frames: 4800), hostSeconds: 0)
        try writer.padSilence(throughHostSeconds: 0.5)
        try writer.append(try buffer(input, frames: 4800, value: -0.9), hostSeconds: 0.2)
        try writer.append(try buffer(input, frames: 4800), hostSeconds: 0.5)
        try writer.finish()
        let samples = try read(url)
        #expect(samples.count == 14400)
        #expect(samples[2400..<12000].allSatisfy { $0 == 0 })
        #expect(samples[2200..<2350].allSatisfy { $0 > 0.2 })
        #expect(writer.profile.gaps == [.init(start: 0.1, duration: 0.4)])
        #expect(writer.capturedFrames == 4800)
    }
    @Test func muteDiscardsPendingPrivateTailEvenIfNoMoreCallbacksArrive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try format(48000)
        let track = try format(24000)
        var muted = false
        var postMute: [Float] = []
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0) { buffer, _ in
            if muted {
                postMute += Array(
                    UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
        }
        try writer.append(try buffer(input, frames: 4800, value: 0.9), hostSeconds: 0)
        writer.setMuted(true)
        muted = true
        try writer.finish()
        #expect(try read(url).count == 2400)
        #expect(!postMute.isEmpty)
        #expect(postMute.allSatisfy { $0 == 0 })
    }
}
