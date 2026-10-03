import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

/// Hardware-independent work bounds. Model output is synthetic; inference is not exercised.
@Suite(.serialized) @MainActor struct StreamingGrowthIntegrationTests {
    @Test(arguments: [false, true]) func transcriptAndSpeakerUpdatesDoNotRevisitHistory(labeling: Bool) throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: labeling, sources: [.microphone, .system])
        let display = LiveTranscriptStreamDisplayCache()
        let session = UUID()
        let generation = UUID()
        let speakers = LiveAudioSource.allCases.map {
            LiveSpeakerIdentity(
                id: UUID(), source: $0, generation: generation, slot: 0, model: "synthetic", revision: "growth")
        }
        if labeling {
            for speaker in speakers {
                stream.accept(
                    LiveSpeakerEvent(
                        source: speaker.source, generation: generation, sequence: 0, speakers: [speaker],
                        intervals: [], start: 0, end: 0))
            }
        }
        var first: TranscriptDisplayRow?
        var checkpoints: [(attributed: Int, rebuilt: Int)] = []
        var maximumAttributed = 0
        var maximumRebuilt = 0
        // Two sources, fixed phrase density, 1 / 10 / 100 minutes of actual event history.
        for index in 0..<3000 {
            let start = Double(index * 2)
            for speaker in speakers {
                let phrase = LiveTranscriptPhrase(
                    session: session, source: speaker.source, start: start, end: start + 1.5,
                    text: "A synthetic sentence.")
                stream.accept(phrase, final: true)
                maximumAttributed = max(maximumAttributed, stream.attributedPhraseCount)
                if labeling {
                    // Delay some labels to exercise the bounded unresolved tail, not only the easy path.
                    if index % 100 >= 20 && !index.isMultiple(of: 7) {
                        stream.accept(
                            LiveSpeakerEvent(
                                source: speaker.source, generation: generation, sequence: index + 1,
                                speakers: [speaker],
                                intervals: [.init(speakerID: speaker.id, start: start, end: start + 1.5)],
                                start: start, end: start + 1.5))
                        maximumAttributed = max(maximumAttributed, stream.attributedPhraseCount)
                    }
                }
                display.update(stream, people: [], enabled: labeling, recognitionEnabled: true)
                maximumRebuilt = max(maximumRebuilt, display.rebuiltParagraphCount)
                #expect(stream.hotFinalized.count + stream.hotPartials.count <= 40)
                #expect(display.count - display.frozenCount <= 40)
            }
            if display.frozenCount > 0 {
                if let first {
                    #expect(display.row(at: 0) == first)
                }
                else {
                    first = display.row(at: 0)
                }
            }
            if [29, 299, 2999].contains(index) {
                checkpoints.append((maximumAttributed, maximumRebuilt))
                maximumAttributed = 0
                maximumRebuilt = 0
                #expect(stream.frozenCount >= index * 2 - 40)
            }
        }
        #expect(checkpoints.count == 3)
        for point in checkpoints {
            // These count real attribution and paragraph rebuild work, not elapsed time.
            #expect(point.attributed <= 40)
            #expect(point.rebuilt <= 45)
        }
        stream.finish()
        display.update(stream, people: [], enabled: labeling, recognitionEnabled: false)
        #expect(stream.frozenCount == 6000)
        #expect(display.count == 6000)
        if labeling {
            #expect(
                Set((5998..<6000).compactMap { stream.frozenRow(at: $0).speakerIdentity }) == Set(speakers.map(\.id)))
        }
    }

    @Test func continuousEncodingWritesBoundedPagesAsRecordingGrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("growth-audio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        for frame in 0..<960 { buffer.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 0.06) }
        var pageBytes: [Int] = []
        let writers = try (0..<2).map { track in
            try SpeechOpusWriter(url: directory.appendingPathComponent("track-\(track).opus"), format: format) {
                handle, bytes in
                pageBytes.append(bytes.count)
                try handle.write(contentsOf: bytes)
            }
        }
        // Keep each capture-side path running continuously; do not restart it at a checkpoint.
        var echo = EchoDetector()
        var writtenWindows: [Int] = []
        for block in 0..<5100 {
            let start = Double(block) * 0.02
            for writer in writers { try writer.append(buffer) }
            let level = RecordingSourceLevel.measure(buffer)
            echo.addMicrophone(meanSquare: pow(10, level.rmsDB / 10), hostTime: start, duration: 0.02)
            echo.addSystem(meanSquare: pow(10, level.rmsDB / 10), hostTime: start, duration: 0.02)
            if block.isMultiple(of: 50) { _ = echo.evaluate() }
            if [49, 499, 4999].contains(block) { pageBytes.removeAll(keepingCapacity: true) }
            if [99, 549, 5049].contains(block) {
                // Equal one-second windows after 1, 10, and 100 seconds of encoded history.
                #expect(pageBytes.count <= 6)
                #expect(pageBytes.allSatisfy { $0 <= 27 + 255 + 20 * 4000 })
                writtenWindows.append(pageBytes.reduce(0, +))
                pageBytes.removeAll(keepingCapacity: true)
            }
        }
        for writer in writers { try writer.finish() }
        #expect(writtenWindows.count == 3)
        // Codec VBR and page alignment vary; history-sized rewrites cannot fit this bound.
        #expect(writtenWindows.allSatisfy { $0 > 0 && $0 < 6 * (27 + 255 + 20 * 4000) })
    }

    @Test(arguments: [100, 1000, 10000]) func captureFanoutBackpressureStaysBounded(packetCount: Int) async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 320)
        let sink = LiveAudioSink()
        let queues = (0..<4).map { _ in LiveAudioQueue() }
        sink.replace([.microphone: queues[0], .system: queues[1]])
        sink.replace([.microphone: queues[2], .system: queues[3]], consumer: UUID())
        // Both transcription and labeling consumers are stalled. PCM and loss records must plateau.
        for index in 0..<packetCount {
            for source in LiveAudioSource.allCases {
                sink.append(buffer, start: Double(index) * 0.02, source: source)
            }
        }
        for queue in queues {
            queue.finish()
            var frames = 0
            for await packet in queue.stream {
                frames += Int(packet.buffer.frameLength)
                #expect(packet.buffer.floatChannelData![0][0] == 0.25)
                queue.consumed(packet)
            }
            #expect(frames > 0)
            #expect(frames <= Int(LiveAudioQueue.maximumSeconds * 16000))
            let gaps = queue.takeDroppedRanges()
            #expect(gaps.count <= LiveAudioQueue.maximumDroppedRanges)
            if packetCount >= 1000 { #expect(!gaps.isEmpty) }
        }
        #expect(sink.positions().count == 2)
        #expect(abs((sink.positions()[.system] ?? 0) - Double(packetCount) * 0.02) < 0.0001)
    }
}
