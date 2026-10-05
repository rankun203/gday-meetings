import AVFoundation
import Foundation

/// Reads only the requested range at the decoder's source rate, averages all channels,
/// then applies the model's sinc resampler once. Playback's 48 kHz converter is not reused.
enum CLSPAudioLoader {
    static func load(url: URL, start: Double, duration: Double) throws -> [Float] {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 30 else {
            throw ServiceError("Choose an audio range of up to 30 seconds.")
        }
        let mono: [Float]
        let rate: Int
        if ["opus", "ogg"].contains(url.pathExtension.lowercased()) {
            let reader = try OpusFileDecoder(url)
            rate = 48000
            let first = min(
                reader.totalFrames, Int64(min(Double(reader.totalFrames), (start * 48000).rounded(.toNearestOrEven))))
            try reader.seek(frame: first)
            let count = min(reader.totalFrames - first, Int64((duration * 48000).rounded(.toNearestOrEven)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 8192) else {
                throw ServiceError("Couldn’t prepare voice search audio decoding.")
            }
            var result = [Float]()
            result.reserveCapacity(Int(count))
            while result.count < count {
                try Task.checkCancellation()
                try reader.read(into: buffer, frames: AVAudioFrameCount(min(8192, Int(count) - result.count)))
                guard buffer.frameLength > 0 else { break }
                let channels = buffer.floatChannelData!
                for frame in 0..<Int(buffer.frameLength) {
                    result.append((channels[0][frame] + channels[1][frame]) / 2)
                }
            }
            mono = result
        }
        else {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate),
                format.sampleRate.rounded() == format.sampleRate, (1...32).contains(format.channelCount),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
            else { throw ServiceError("The audio format is not supported for voice search.") }
            rate = Int(format.sampleRate)
            let first = AVAudioFramePosition(
                min(Double(file.length), (start * format.sampleRate).rounded(.toNearestOrEven)))
            file.framePosition = first
            let count = min(
                file.length - first, AVAudioFramePosition((duration * format.sampleRate).rounded(.toNearestOrEven)))
            var result = [Float]()
            result.reserveCapacity(Int(count))
            while result.count < count {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, Int(count) - result.count)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    var value: Float = 0
                    for channel in 0..<Int(format.channelCount) { value += channels[channel][frame] }
                    result.append(value / Float(format.channelCount))
                }
            }
            mono = result
        }
        guard mono.count >= rate / 4 else {
            throw ServiceError("Voice search needs at least a quarter second of audio.")
        }
        return try CLSPSincResampler.resample(mono, from: rate)
    }
}
