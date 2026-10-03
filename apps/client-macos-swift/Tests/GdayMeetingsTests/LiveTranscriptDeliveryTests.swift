import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptDeliveryTests {
    actor GapReceiver {
        var gaps: [LiveTranscriptGap] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var arrived: CheckedContinuation<Void, Never>?
        private var started = false
        func receive(_ gap: LiveTranscriptGap) async {
            gaps.append(gap)
            if !started {
                started = true
                arrived?.resume()
                arrived = nil
                await withCheckedContinuation { gate = $0 }
            }
        }
        func waitForStart() async {
            if !started { await withCheckedContinuation { arrived = $0 } }
        }
        func release() {
            gate?.resume()
            gate = nil
        }
    }

    @Test func blockedGapDeliveryIsBoundedAndFinalDrainRetainsCoverage() async {
        let receiver = GapReceiver()
        let reporter = LiveTranscriptGapReporter(limit: 4) { await receiver.receive($0) }
        reporter.append(.init(source: .system, start: 0, end: 1, reason: "Input interrupted."))
        await receiver.waitForStart()
        for index in 1...100 {
            reporter.append(
                .init(
                    source: .system, start: Double(index * 2), end: Double(index * 2 + 1), reason: "Input interrupted.")
            )
        }
        await receiver.release()
        await reporter.flush()
        let gaps = await receiver.gaps
        #expect(gaps.count <= 5)
        #expect(gaps.last?.reason == LiveTranscriptGapReporter.uncertainReason)
        for index in 1...100 {
            #expect(gaps.contains { $0.start <= Double(index * 2) && $0.end >= Double(index * 2 + 1) })
        }
    }

    @Test func gapCoalescingPreservesSourceAndReason() async {
        let receiver = GapReceiver()
        let reporter = LiveTranscriptGapReporter { await receiver.receive($0) }
        reporter.append(.init(source: .system, start: 0, end: 1, reason: "First interruption."))
        await receiver.waitForStart()
        reporter.append(.init(source: .system, start: 2, end: 3, reason: "Input interrupted."))
        reporter.append(.init(source: .system, start: 3, end: 4, reason: "Input interrupted."))
        reporter.append(.init(source: .microphone, start: 3, end: 4, reason: "Input interrupted."))
        reporter.append(.init(source: .system, start: 3, end: 4, reason: "Different interruption."))
        await receiver.release()
        await reporter.flush()
        let gaps = await receiver.gaps
        #expect(gaps.count == 4)
        #expect(gaps[1].start == 2 && gaps[1].end == 4)
    }

    @Test func saturatedMailboxPreservesNewSourceAndRejectsInvalidRanges() async {
        let receiver = GapReceiver()
        let reporter = LiveTranscriptGapReporter(limit: 2) { await receiver.receive($0) }
        reporter.append(.init(source: .microphone, start: 0, end: 1, reason: "Input interrupted."))
        await receiver.waitForStart()
        reporter.append(.init(source: .microphone, start: 2, end: 3, reason: "Input interrupted."))
        reporter.append(.init(source: .microphone, start: 4, end: 5, reason: "Input interrupted."))
        reporter.append(.init(source: .system, start: 6, end: 7, reason: "Input interrupted."))
        reporter.append(.init(source: .system, start: .nan, end: 8, reason: "Invalid range."))
        reporter.append(.init(source: .system, start: 9, end: 8, reason: "Invalid range."))
        await receiver.release()
        await reporter.flush()
        let gaps = await receiver.gaps
        #expect(gaps.count == 3)
        #expect(gaps[1].source == .microphone && gaps[1].start == 2 && gaps[1].end == 5)
        #expect(gaps[1].reason == LiveTranscriptGapReporter.uncertainReason)
        #expect(gaps[2].source == .system && gaps[2].start == 6 && gaps[2].end == 7)
    }

    @Test(arguments: [512, 4800])
    func pullInputUsesDurationBudgetAndContinuesAfterDeviceGap(frames: AVAudioFrameCount) async throws {
        guard #available(macOS 26.0, *) else { return }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
        let queue = LiveAudioQueue()
        let receiver = GapReceiver()
        let reporter = LiveTranscriptGapReporter { await receiver.receive($0) }
        let input = AppleLiveAudioInput(
            queue: queue, format: format, boundary: 0, source: frames == 512 ? .system : .microphone,
            reporter: reporter, failure: { _ in })
        let count = Int(1.5 * 48000 / Double(frames))
        for index in 0..<count { queue.append(buffer, start: Double(index * Int(frames)) / 48000) }
        // More than eight tiny packets wait safely without an analyzer consumer.
        #expect(queue.takeDroppedRanges().isEmpty)
        for _ in 0..<count { #expect(await input.next() != nil) }
        let resumedFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let resumed = try #require(AVAudioPCMBuffer(pcmFormat: resumedFormat, frameCapacity: 1600))
        resumed.frameLength = 1600
        resumed.floatChannelData![0].update(repeating: 0, count: 1600)
        queue.append(resumed, start: 3)
        queue.finish()
        let next = await input.next()
        #expect(next != nil)
        #expect(next?.bufferStartTime?.seconds == 3)
        await receiver.waitForStart()
        // A stalled UI callback does not block the analyzer from reaching end of input.
        #expect(await input.next() == nil)
        await receiver.release()
        await reporter.flush()
        let gaps = await receiver.gaps
        #expect(gaps.count == 1)
        #expect(abs((gaps.first?.start ?? 0) - Double(count * Int(frames)) / 48000) < 0.000_001)
        #expect(gaps.first?.end == 3)
    }
}
