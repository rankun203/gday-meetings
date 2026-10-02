import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct LiveAudioInputTimelineTests {
    @Test func actualResamplingPreservesContiguousFramesAndShortGaps() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let outputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = LivePCMConverter(output: outputFormat)
        var timeline = LiveAudioInputTimeline(boundary: 2)
        var previousOutputEnd: Int64?
        for group in 0..<3 {
            // Ten 20 ms packets, then 20 ms of missing input. These are recording
            // timestamps, independent of how many frames the converter releases.
            let origin = 2 + Double(group) * 0.22
            let anchor = Int64((origin * 16_000).rounded())
            var producedFrames: Int64 = 0
            var outputBuffers = 0
            for packet in 0..<10 {
                let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 960))
                input.frameLength = 960
                let channel = try #require(input.floatChannelData?[0])
                for frame in 0..<960 {
                    channel[frame] = Float(sin(Double(packet * 960 + frame) * 2 * .pi * 440 / 48_000)) * 0.1
                }
                let gap = timeline.receive(start: origin + Double(packet) * 0.02, duration: 0.02)
                #expect(gap == (group > 0 && packet == 0))
                if gap { converter.reset() }
                guard let output = try converter.convert(input) else { continue }
                let convertedStart = timeline.convertedStart(frameCount: Int(output.frameLength), sampleRate: 16_000)
                let start = try #require(convertedStart)
                #expect(start == anchor + producedFrames)
                if outputBuffers == 0, let previousOutputEnd {
                    // A continuous cursor would erase this recording-time gap.
                    #expect(start - previousOutputEnd >= 320)
                }
                producedFrames += Int64(output.frameLength)
                previousOutputEnd = start + Int64(output.frameLength)
                outputBuffers += 1
            }
            #expect(outputBuffers > 0)
            #expect(producedFrames > 0)
        }
    }

    @Test func shortRepeatedGapsPreserveRecordingTime() {
        var timeline = LiveAudioInputTimeline(boundary: 0)
        for index in 0..<20 {
            let start = Double(index) * 0.04
            let result1 = timeline.receive(start: start, duration: 0.02)
            #expect(result1 == (index > 0))
            let result2 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
            #expect(result2 == Int64(index * 640))
        }
    }

    @Test func converterCarryDoesNotReanchorContiguousPackets() {
        var timeline = LiveAudioInputTimeline(boundary: 2)
        let result3 = timeline.receive(start: 2, duration: 0.02)
        #expect(!result3)
        let result4 = timeline.convertedStart(frameCount: 280, sampleRate: 16_000)
        #expect(result4 == 32_000)
        let result5 = timeline.receive(start: 2.02, duration: 0.02)
        #expect(!result5)
        let result6 = timeline.convertedStart(frameCount: 360, sampleRate: 16_000)
        #expect(result6 == 32_280)
        let result7 = timeline.receive(start: 2.04, duration: 0.02)
        #expect(!result7)
        let result8 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result8 == 32_640)
    }

    @Test func initialEmptyConversionKeepsFirstInputOrigin() {
        var timeline = LiveAudioInputTimeline(boundary: 0)
        let result9 = timeline.receive(start: 3, duration: 0.01)
        #expect(result9)
        let result10 = timeline.convertedStart(frameCount: 0, sampleRate: 16_000)
        #expect(result10 == nil)
        let result11 = timeline.receive(start: 3.01, duration: 0.01)
        #expect(!result11)
        let result12 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result12 == 48_000)
        let result13 = timeline.receive(start: 3.04, duration: 0.02)
        #expect(result13)
        let result14 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result14 == 48_640)
    }

    @Test func roundingNoiseAndInvalidPacketsDoNotRewindCursor() {
        var timeline = LiveAudioInputTimeline(boundary: 1)
        let result15 = timeline.receive(start: 1, duration: 0.02)
        #expect(!result15)
        let result16 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result16 == 16_000)
        let result17 = timeline.receive(start: 1.02 + 0.000_001, duration: 0.02)
        #expect(!result17)
        let result18 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result18 == 16_320)
        let end = timeline.previousEnd
        let result19 = timeline.receive(start: 0.5, duration: 0.02)
        #expect(!result19)
        let result20 = timeline.receive(start: .nan, duration: 0.02)
        #expect(!result20)
        let result21 = timeline.receive(start: 2, duration: -.infinity)
        #expect(!result21)
        #expect(timeline.previousEnd == end)
        let result22 = timeline.convertedStart(frameCount: 320, sampleRate: 16_000)
        #expect(result22 == 16_640)
        #expect(!LiveAudioInputTimeline.hasGap(from: 1, to: .infinity))
    }
}
