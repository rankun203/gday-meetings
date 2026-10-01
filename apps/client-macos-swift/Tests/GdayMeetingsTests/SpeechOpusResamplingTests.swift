import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct SpeechOpusResamplingTests {
    @Test func resamplingPreservesPulseAlignmentAndAudioBeforeEOF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let native = try roundtrip(rate: 48000, url: root.appendingPathComponent("native.opus"))
        let resampled = try roundtrip(rate: 16000, url: root.appendingPathComponent("resampled.opus"))
        try #require(native.count == 48000)
        try #require(resampled.count == native.count)

        // Compare an interior pulse and one just 1 ms before EOF. Duration alone
        // cannot detect a resampler delay that shifts audio past the final granule.
        for center in [38400, 47952] {
            let window = (center - 240)..<min(center + 240, native.count)
            let nativePeak = try #require(window.max { abs(native[$0]) < abs(native[$1]) })
            let resampledPeak = try #require(window.max { abs(resampled[$0]) < abs(resampled[$1]) })
            #expect(abs(native[nativePeak]) > 0.2)
            #expect(abs(resampled[resampledPeak]) > 0.2)
            // Allow codec ringing, but not the 48-frame delay from .none priming
            // at 16 kHz. With normal priming both peaks align in the roundtrip.
            #expect(abs(nativePeak - center) <= 8)
            #expect(abs(resampledPeak - nativePeak) <= 8)
        }

        let tail = 47712..<48000
        let nativeEnergy = tail.reduce(0.0) { $0 + Double(native[$1]) * Double(native[$1]) }
        let resampledEnergy = tail.reduce(0.0) { $0 + Double(resampled[$1]) * Double(resampled[$1]) }
        #expect(resampledEnergy > nativeEnergy * 0.75, "End trimming must retain the final pulse.")
    }

    private func roundtrip(rate: Double, url: URL) throws -> [Float] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 997))
        let writer = try SpeechOpusWriter(url: url, format: format)
        let total = Int(rate)
        var position = 0
        while position < total {
            input.frameLength = UInt32(min(997, total - position))
            for index in 0..<Int(input.frameLength) {
                let time = Double(position + index) / rate
                // Smooth synthetic impulses limit high-frequency differences
                // between the two input rates while exposing submillisecond shifts.
                let interior = (time - 0.8) / 0.0002
                let ending = (time - 0.999) / 0.0002
                input.floatChannelData![0][index] = Float(
                    0.8 * (exp(-0.5 * interior * interior) + exp(-0.5 * ending * ending)))
            }
            try writer.append(input)
            position += Int(input.frameLength)
        }
        try writer.finish()

        let decoder = try OpusFileDecoder(url)
        try #require(decoder.totalFrames == 48000)
        #expect(decoder.channels == 1)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 1024))
        var decoded: [Float] = []
        decoded.reserveCapacity(Int(decoder.totalFrames))
        while decoded.count < Int(decoder.totalFrames) {
            let count = min(Int(output.frameCapacity), Int(decoder.totalFrames) - decoded.count)
            try decoder.read(into: output, frames: UInt32(count))
            try #require(output.frameLength > 0, "Audio ended before the declared duration.")
            decoded.append(
                contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        return decoded
    }
}
