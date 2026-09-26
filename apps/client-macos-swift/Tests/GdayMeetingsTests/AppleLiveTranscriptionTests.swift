import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct AppleLiveTranscriptionTests {
    /// Explicitly enabled only: generated speech, no microphone or cloud transcription.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_APPLE_LIVE_TEST"] == "1"))
    func generatedEnglishAndMandarin() async throws {
        guard #available(macOS 26.0, *) else { return }
        for (language, voice, text) in [
            (
                "en", "Karen",
                "This is a test meeting. We agreed to finish the report on Friday. Alex will review the notes."
            ),
            ("zh-cn", "Tingting", "这是一次测试会议。我们决定星期五完成报告。请检查会议记录。"),
        ] {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).aiff")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-o", fileURL.path, text]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let locale = try await AppleLiveTranscription.prepare(language: language) { _ in }
            let provider = AppleLiveTranscription()
            let sink = LiveAudioSink()
            let collection = Results()
            try await provider.start(
                locale: locale, sources: [.microphone, .system], sink: sink,
                receive: { phrase, final in await collection.receive(phrase, final: final) },
                gap: { _ in }, failure: { message in await collection.fail(message) })
            let file = try AVAudioFile(forReading: fileURL)
            let count = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            var position = 0.0
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: buffer)
                sink.append(buffer, start: position, source: .microphone)
                sink.append(buffer, start: position, source: .system)
                let duration = Double(buffer.frameLength) / file.processingFormat.sampleRate
                position += duration
                try await Task.sleep(for: .seconds(duration))
            }
            sink.replace([:])
            let complete = await provider.finish()
            let result = await collection.snapshot()
            #expect(complete)
            #expect(result.1.isEmpty)
            #expect(result.0.contains { $0.source == .microphone && !$0.text.isEmpty })
            #expect(result.0.contains { $0.source == .system && !$0.text.isEmpty })
            #expect(result.0.allSatisfy { $0.start.isFinite && $0.end >= $0.start && $0.locale == locale.identifier })
            // Output is generated test text only, useful for spotting empty or wrong-language results.
            print(
                "Apple live smoke \(locale.identifier): \(result.0.filter { $0.source == .microphone }.map(\.text).joined())"
            )
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_LOCAL_LIVE_RECORDING"] != nil))
    func authorizedLocalRecordingExcerpt() async throws {
        guard #available(macOS 26.0, *), let path = ProcessInfo.processInfo.environment["GDAY_LOCAL_LIVE_RECORDING"]
        else { return }
        let directory = URL(fileURLWithPath: path)
        let locale = try await AppleLiveTranscription.prepare(language: "en") { _ in }
        let provider = AppleLiveTranscription()
        let sink = LiveAudioSink()
        let collection = Results()
        try await provider.start(
            locale: locale, sources: [.microphone, .system], sink: sink,
            receive: { phrase, final in await collection.receive(phrase, final: final) },
            gap: { _ in }, failure: { message in await collection.fail(message) })
        let microphone = try StreamingAudioReader.open(directory.appendingPathComponent("system_microphone.opus"))
        let system = try StreamingAudioReader.open(directory.appendingPathComponent("system_audio.opus"))
        let start = 60.0
        try microphone.seek(frame: Int64(start * 48000))
        try system.seek(frame: Int64(start * 48000))
        for index in 0..<900 {
            for (source, reader) in [(LiveAudioSource.microphone, microphone), (.system, system)] {
                let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 4800)!
                try reader.read(into: buffer, frames: 4800)
                sink.append(buffer, start: start + Double(index) / 10, source: source)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        sink.replace([:])
        #expect(await provider.finish())
        let result = await collection.snapshot()
        #expect(result.1.isEmpty)
        #expect(!result.0.isEmpty)
        #expect(result.0.allSatisfy { $0.start >= start - 0.25 && $0.end <= start + 91 })
        print(
            "Local live excerpt: \(result.0.count) final phrases, valid 60–150 second timeline; no transcript text logged."
        )
    }

    actor Results {
        var phrases: [LiveTranscriptPhrase] = []
        var failures: [String] = []
        func receive(_ phrase: LiveTranscriptPhrase, final: Bool) { if final { phrases.append(phrase) } }
        func fail(_ message: String) { failures.append(message) }
        func snapshot() -> ([LiveTranscriptPhrase], [String]) { (phrases, failures) }
    }
}
