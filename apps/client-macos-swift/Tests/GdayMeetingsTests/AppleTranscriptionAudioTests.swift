import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct AppleTranscriptionAudioTests {
    private func fixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.17) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func readablePCMNeedsNoConverter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let result = try await AppleTranscriptionAudio.prepare(source, ffmpeg: nil, status: { _ in })
        #expect(result.url == source)
        #expect(!result.temporary)
    }

    @Test func unreadableAudioExplainsRecovery() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("invalid synthetic audio".utf8).write(to: source)
        do {
            _ = try await AppleTranscriptionAudio.prepare(source, ffmpeg: nil, status: { _ in })
            Issue.record("Unreadable audio was accepted")
        }
        catch {
            #expect(error.localizedDescription.contains("couldn’t decode"))
            #expect(error.localizedDescription.contains("PCM WAV or AIFF"))
            #expect(error.localizedDescription.contains("Install FFmpeg and choose Resume"))
        }
    }

    @Test func cancellationIsNotAFormatFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleTranscriptionAudio.prepare(source, ffmpeg: nil, status: { _ in })
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled preparation succeeded")
        }
        catch { #expect(error is CancellationError) }
    }

    @Test(.enabled(if: AppleTranscriptionAudio.findFFmpeg() != nil), arguments: ["pcm_s16le", "aac"])
    func unsupportedContainerRecovers(codec: String) async throws {
        let executable = try #require(AppleTranscriptionAudio.findFFmpeg())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try fixture(in: directory)
        let source = directory.appendingPathComponent("sample.mka")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-v", "error", "-i", wav.path, "-c:a", codec, source.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let original = try Data(contentsOf: source)
        let result = try await AppleTranscriptionAudio.prepare(source, ffmpeg: executable, status: { _ in })
        defer { if result.temporary { try? FileManager.default.removeItem(at: result.url) } }
        #expect(result.temporary)
        #expect(result.url.pathExtension == (codec == "aac" ? "m4a" : "opus"))
        try AppleTranscriptionAudio.validate(result.url)
        if codec == "aac" {
            let decoded = try AVAudioFile(forReading: result.url)
            #expect(abs(decoded.length - 16000) <= 2048)
            #expect(decoded.processingFormat.sampleRate == 16000)
            #expect(decoded.processingFormat.channelCount == 1)
        }
        else {
            let decoded = try OpusFileDecoder(result.url)
            #expect(decoded.totalFrames == 48000)
            #expect(decoded.channels == 1)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func opusStreamsThroughFinalPartialBufferWithoutSpool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try fixture(in: directory)
        let source = directory.appendingPathComponent("sample.opus")
        try await RecordingEncoder.encode(source: wav, destination: source, format: .opus)
        let prepared = try await AppleTranscriptionAudio.prepare(source, ffmpeg: nil, status: { _ in })
        #expect(prepared.url == source)
        #expect(!prepared.temporary)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let stream = try RecordedOpusInput(file: source, format: format)
        var frames: Int64 = 0
        var blocks = 0
        while let item = try await stream.nextBuffer() {
            #expect(item.start.value == frames)
            #expect(item.buffer.frameLength <= 4096)
            #expect(item.buffer.format == format)
            frames += Int64(item.buffer.frameLength)
            blocks += 1
        }
        #expect(frames == 16000)
        #expect(blocks == 4)
        #expect(try await stream.nextBuffer() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
    }

    @Test func opusStreamingHonorsCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try fixture(in: directory)
        let opus = directory.appendingPathComponent("sample.opus")
        try await RecordingEncoder.encode(source: wav, destination: opus, format: .opus)
        let stream = try RecordedOpusInput(file: opus, format: StreamingAudioReader.format)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stream.nextBuffer()
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled input yielded audio")
        }
        catch { #expect(error is CancellationError) }
    }

    @Test func opusResamplingRetainsPulseImmediatelyBeforeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pulse.opus")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for index in 0..<48000 {
            let distance = (Double(index) / 48000 - 0.999) / 0.0002
            buffer.floatChannelData![0][index] = Float(0.8 * exp(-0.5 * distance * distance))
        }
        let writer = try SpeechOpusWriter(url: file, format: format)
        try writer.append(buffer)
        try writer.finish()
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let stream = try RecordedOpusInput(file: file, format: outputFormat)
        var samples: [Float] = []
        while let item = try await stream.nextBuffer() {
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: item.buffer.floatChannelData![0], count: Int(item.buffer.frameLength)))
        }
        #expect(samples.count == 16000)
        let peak = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
        #expect(abs(samples[peak]) > 0.2)
        #expect(abs(peak - 15984) <= 3)
    }

    @Test(.enabled(if: AppleTranscriptionAudio.findFFmpeg() != nil))
    func damagedInputIsNotReplacedWithPartialAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("damaged.mka")
        let bytes = Data("invalid synthetic audio".utf8)
        try bytes.write(to: source)
        do {
            _ = try await AppleTranscriptionAudio.prepare(source, status: { _ in })
            Issue.record("Damaged audio was accepted")
        }
        catch {
            #expect(error.localizedDescription.contains("FFmpeg couldn’t create readable audio"))
        }
        #expect(try Data(contentsOf: source) == bytes)
    }

}
