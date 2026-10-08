import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct LiveAudioTransportTests {
    @Test func changingCaptureFormatsKeepsFileAndSubscriberTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("microphone.wav")
        let sink = LiveAudioSink()
        let transcription = LiveAudioQueue()
        let labeling = LiveAudioQueue()
        sink.replace([.microphone: transcription])
        sink.replace([.microphone: labeling], consumer: UUID())
        let initial = try buffer(rate: 48_000, channels: 2, seconds: 0.1)
        let writer = try TimedAudioWriter(
            url: url, format: initial.format, epoch: 100,
            alignedAudio: { sink.append($0, start: $1, source: .microphone) })

        // Synthetic built-in, wireless, and returning built-in formats. The
        // writer and subscriptions stay installed across both missing intervals.
        try writer.append(initial, hostSeconds: 100)
        try writer.padSilence(throughHostSeconds: 100.25)
        try writer.append(buffer(rate: 24_000, channels: 1, seconds: 0.1), hostSeconds: 100.3)
        try writer.append(buffer(rate: 44_100, channels: 2, seconds: 0.1), hostSeconds: 100.5)
        try writer.finish(throughHostSeconds: 100.75)
        transcription.finish()
        labeling.finish()
        let packets = await drain(transcription)
        let speakerPackets = await drain(labeling)
        #expect(speakerPackets.map(\.start) == packets.map(\.start))
        #expect(speakerPackets.map(\.duration) == packets.map(\.duration))
        #expect(packets.allSatisfy { $0.buffer.format.sampleRate == 48_000 && $0.buffer.format.channelCount == 2 })
        #expect(transcription.takeDroppedRanges().isEmpty)
        #expect(labeling.takeDroppedRanges().isEmpty)
        #expect(sink.positions()[.system] == nil)
        let end = try #require(sink.positions()[.microphone])
        let last = try #require(packets.last)
        #expect(end == last.start + last.duration)
        #expect(abs(end - 0.6) < 1.0 / 48_000)

        // Draining a route's converter may emit an extra short packet. These
        // packets must complete that route's speech, not introduce a new gap.
        var timeline = LiveAudioInputTimeline(boundary: 0)
        var runs: [Range<Int64>] = []
        var gapStarts: [Int64] = []
        for packet in packets {
            let packetStart = Int64((packet.start * 48_000).rounded())
            let frameCount = Int(packet.buffer.frameLength)
            let packetEnd = packetStart + Int64(frameCount)
            if timeline.receive(start: packet.start, duration: packet.duration) {
                gapStarts.append(packetStart)
            }
            #expect(timeline.convertedStart(frameCount: frameCount, sampleRate: 48_000) == packetStart)
            if let last = runs.last, last.upperBound == packetStart {
                runs[runs.count - 1] = last.lowerBound..<packetEnd
            }
            else {
                runs.append(packetStart..<packetEnd)
            }
        }
        #expect(runs == [0..<4_800, 14_400..<19_200, 24_000..<28_800])
        #expect(gapStarts == [14_400, 24_000])
        #expect(packets.reduce(0) { $0 + Int($1.buffer.frameLength) } == 14_400)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 36_000)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        let recorded = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 36_000))
        try file.read(into: recorded)
        for (packet, duplicate) in zip(packets, speakerPackets) {
            let offset = Int((packet.start * 48_000).rounded())
            for channel in 0..<2 {
                let samples = try #require(packet.buffer.floatChannelData?[channel])
                let other = try #require(duplicate.buffer.floatChannelData?[channel])
                let saved = try #require(recorded.floatChannelData?[channel])
                let count = Int(packet.buffer.frameLength)
                #expect((0..<count).allSatisfy { abs(samples[$0] - other[$0]) < 0.000_001 })
                #expect((0..<count).allSatisfy { abs(samples[$0] - saved[offset + $0]) < 0.000_1 })
            }
        }
        #expect(writer.profile.gaps.contains { abs($0.start - 0.1) < 0.001 && abs($0.duration - 0.2) < 0.001 })
    }

    @Test func stalledMicrophoneConsumerDoesNotDropSystemOrOtherSubscriber() async throws {
        let sink = LiveAudioSink()
        let stalled = LiveAudioQueue()
        let fastMicrophone = LiveAudioQueue()
        let system = LiveAudioQueue()
        let alternate = UUID()
        sink.replace([.microphone: stalled, .system: system])
        sink.replace([.microphone: fastMicrophone], consumer: alternate)
        var microphoneIterator = fastMicrophone.stream.makeAsyncIterator()
        var systemIterator = system.stream.makeAsyncIterator()
        let samples = try buffer(rate: 16_000, channels: 1, seconds: 0.5)
        for index in 0..<12 {
            let start = Double(index) * 0.5
            sink.append(samples, start: start, source: .microphone)
            sink.append(samples, start: start, source: .system)
            let micPacket = try #require(await microphoneIterator.next())
            let systemPacket = try #require(await systemIterator.next())
            #expect(micPacket.start == start)
            #expect(systemPacket.start == start)
            fastMicrophone.consumed(micPacket)
            system.consumed(systemPacket)
        }
        stalled.finish()
        let waiting = await drain(stalled)
        #expect(waiting.count == 4)
        #expect(waiting.reduce(0) { $0 + $1.duration } == LiveAudioQueue.maximumSeconds)
        let dropped = stalled.takeDroppedRanges()
        #expect(dropped.count == 1)
        #expect(dropped.first?.start == 2)
        #expect(dropped.first?.end == 6)
        #expect(fastMicrophone.takeDroppedRanges().isEmpty)
        #expect(system.takeDroppedRanges().isEmpty)
        #expect(sink.positions()[.microphone] == 6)
        #expect(sink.positions()[.system] == 6)
        fastMicrophone.finish()
        system.finish()
    }

    @Test func replacingOneSubscriberPreservesOtherAndRecordingPosition() async throws {
        let sink = LiveAudioSink()
        let previous = LiveAudioQueue()
        let replacement = LiveAudioQueue()
        let labeling = LiveAudioQueue()
        let consumer = UUID()
        sink.replace([.microphone: previous])
        sink.replace([.microphone: labeling], consumer: consumer)
        let samples = try buffer(rate: 16_000, channels: 1, seconds: 0.25)
        sink.append(samples, start: 1, source: .microphone)
        sink.replace([.microphone: replacement])
        sink.append(samples, start: 2, source: .microphone)
        sink.replace([:], consumer: consumer)
        sink.append(samples, start: 3, source: .microphone)
        previous.finish()
        replacement.finish()
        labeling.finish()
        let before = await drain(previous)
        let after = await drain(replacement)
        let speakers = await drain(labeling)
        #expect(before.map(\.start) == [1])
        #expect(after.map(\.start) == [2, 3])
        #expect(speakers.map(\.start) == [1, 2])
        #expect(sink.positions()[.microphone] == 3.25)
    }

    @Test func invalidSinkPacketsDoNotPoisonRecordingPositionOrReachSubscribers() async throws {
        let sink = LiveAudioSink()
        let queue = LiveAudioQueue()
        sink.replace([.microphone: queue])
        let samples = try buffer(rate: 16_000, channels: 1, seconds: 0.25)
        for start in [Double.nan, .infinity, -.infinity, -1] {
            sink.append(samples, start: start, source: .microphone)
        }
        #expect(sink.positions().isEmpty)
        sink.append(samples, start: 3, source: .microphone)
        samples.frameLength = 0
        sink.append(samples, start: 100, source: .microphone)
        queue.finish()
        let packets = await drain(queue)
        #expect(packets.map(\.start) == [3])
        #expect(sink.positions()[.microphone] == 3.25)
        #expect(queue.takeDroppedRanges().isEmpty)
    }

    @Test func stalledConsumerLossMetadataIsBoundedAndMarksImpreciseCoverage() async throws {
        let queue = LiveAudioQueue()
        let samples = try buffer(rate: 16_000, channels: 1, seconds: 0.5)
        for index in 0..<4 { queue.append(samples, start: Double(index) * 0.5) }
        // Disjoint missing intervals cannot be represented as a precise single
        // gap. Keep a bounded prefix and mark the overflow span as uncertain.
        for index in 2..<10_002 { queue.append(samples, start: Double(index)) }
        let losses = queue.takeDroppedRanges()
        #expect(losses.count == LiveAudioQueue.maximumDroppedRanges)
        #expect(losses.dropLast().allSatisfy { $0.isExact })
        #expect(losses.last?.isExact == false)
        #expect(losses.first?.start == 2)
        #expect(losses.last?.end == 10_001.5)
        #expect(queue.takeDroppedRanges().isEmpty)
        queue.append(samples, start: 10_003)
        #expect(queue.takeDroppedRanges() == [LiveAudioLoss(start: 10_003, end: 10_003.5)])
        queue.finish()
        let retained = await drain(queue)
        #expect(retained.count == 4)
    }

    @Test func queueRejectsOversizedAndInvalidPacketsAndDrainsAtFinish() async throws {
        let queue = LiveAudioQueue()
        let samples = try buffer(rate: 16_000, channels: 1, seconds: 0.02)
        queue.append(samples, start: .nan)
        queue.append(samples, start: -1)
        queue.append(samples, start: .infinity)
        queue.append(try buffer(rate: 16_000, channels: 1, seconds: 3), start: 0)
        let oversized = queue.takeDroppedRanges()
        #expect(oversized.count == 1)
        #expect(oversized.first?.start == 0)
        #expect(oversized.first?.end == 3)
        for index in 0..<200 { queue.append(samples, start: Double(index) * 0.02) }
        queue.finish()
        queue.append(samples, start: 10)
        let packets = await drain(queue)
        #expect(packets.count >= 99 && packets.count <= 100)
        #expect(packets.reduce(0) { $0 + $1.duration } <= LiveAudioQueue.maximumSeconds)
        #expect(packets.allSatisfy { $0.start < 2 })
        #expect(queue.takeDroppedRanges().allSatisfy { $0.end <= 4 })
    }

    private func buffer(rate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let count = AVAudioFrameCount((rate * seconds).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(count) { samples[frame] = 0.1 }
        }
        return buffer
    }

    private func drain(_ queue: LiveAudioQueue) async -> [LiveAudioQueue.Packet] {
        var result: [LiveAudioQueue.Packet] = []
        for await packet in queue.stream {
            result.append(packet)
            queue.consumed(packet)
        }
        return result
    }
}
