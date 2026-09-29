import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct TimedAudioWriterTests {
    @Test func mutingSuppressesSavedAndLiveSamplesWithoutCollapsingTime() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let changedDevice = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        var liveStarts: [Double] = []
        var liveValues: [Float] = []
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 20) { buffer, start in
            liveStarts.append(start)
            liveValues.append(buffer.floatChannelData![0][0])
        }
        try writer.append(try constant(format, frames: 800, values: [0.25]), hostSeconds: 20)
        writer.setMuted(true)
        // A rebuilt source can change formats while muted; no samples from it
        // may reach the file or the live consumer, including on resumption.
        try writer.append(try constant(changedDevice, frames: 3200, values: [0.9, 0.9]), hostSeconds: 20.1)
        #expect(writer.isMuted)
        writer.setMuted(false)
        try writer.append(try constant(format, frames: 800, values: [0.5]), hostSeconds: 20.3)
        try writer.finish()
        let samples = try read(url)[0]
        #expect(samples.count == 3200)
        #expect(samples[800..<2400].allSatisfy { abs($0) < 0.0001 })
        #expect(abs(samples[100] - 0.25) < 0.0001)
        #expect(abs(samples[2500] - 0.5) < 0.0001)
        #expect(liveStarts == [0, 0.1, 0.3])
        #expect(liveValues == [0.25, 0, 0.5])
        #expect(writer.capturedFrames == 3200)
    }

    @Test func mutedTrackRemainsIndependentAndCanFinishEntirelySilent() throws {
        let mutedURL = temporaryWAV()
        let otherURL = temporaryWAV()
        defer {
            try? FileManager.default.removeItem(at: mutedURL)
            try? FileManager.default.removeItem(at: otherURL)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        var liveSamples: [Float] = []
        let muted = try TimedAudioWriter(url: mutedURL, format: format, epoch: 0) { buffer, _ in
            liveSamples += Array(
                UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let other = try TimedAudioWriter(url: otherURL, format: format, epoch: 0)
        muted.setMuted(true)
        let buffer = try constant(format, frames: 800, values: [0.75])
        try muted.append(buffer, hostSeconds: 0)
        try other.append(buffer, hostSeconds: 0)
        try muted.finish()
        try other.finish()
        #expect(liveSamples.count == 800)
        #expect(liveSamples.allSatisfy { $0 == 0 })
        #expect(muted.capturedFrames == 800)
        #expect(try read(mutedURL)[0].allSatisfy { $0 == 0 })
        #expect(try read(otherURL)[0].allSatisfy { abs($0 - 0.75) < 0.0001 })
        // Muting never alters the capture buffer shared with other consumers.
        #expect(buffer.floatChannelData![0][0] == 0.75)
    }

    @Test func hostTimelinePadsGapsAndTrimsOverlaps() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try constant(format, frames: 480, values: [0.5])
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 10)
        try writer.append(buffer, hostSeconds: 10.01)  // 480 silent frames, then 480 source frames.
        try writer.append(buffer, hostSeconds: 10.015)  // 240 overlapping frames trimmed.
        try writer.append(buffer, hostSeconds: 10.03)  // 240 silent missing frames.
        try writer.finish()
        let samples = try read(url)
        #expect(samples.count == 1)
        #expect(samples[0].count == 1920)
        #expect(abs(samples[0][20]) < 0.0001)
        #expect(abs(samples[0][600] - 0.5) < 0.0001)
        #expect(abs(samples[0][1300]) < 0.0001)
        #expect(abs(samples[0][1500] - 0.5) < 0.0001)
        // Short startup and jitter holes are padded but not reported as outages.
        #expect(writer.profile.gaps.isEmpty)
    }

    @Test func differentDeviceFormatIsConvertedToTrackFormat() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let device = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true))
        let buffer = try constant(device, frames: 441, values: [0.25, 0.75])
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0)
        for index in 0..<100 { try writer.append(buffer, hostSeconds: Double(index) * 0.01) }
        try writer.finish()
        let samples = try read(url)
        #expect(samples.count == 1)
        // The resampler may hold back a few frames, but time is not stretched or compressed.
        #expect(abs(samples[0].count - 48000) < 128)
        // Stereo averages to mono: (0.25 + 0.75) / 2.
        #expect(abs(samples[0][24000] - 0.5) < 0.01)
        #expect(writer.profile.sampleRate == 48000)
        #expect(writer.profile.channels == 1)
    }

    @Test func monoSourceIsDuplicatedIntoStereoTrack() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let device = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try TimedAudioWriter(url: url, format: track, epoch: 0)
        try writer.append(try constant(device, frames: 480, values: [0.3]), hostSeconds: 0)
        try writer.finish()
        let samples = try read(url)
        #expect(samples.map(\.count) == [480, 480])
        #expect(abs(samples[0][100] - 0.3) < 0.001)
        #expect(abs(samples[1][100] - 0.3) < 0.001)
    }

    @Test func longOutageIsPaddedAndReportedAsOneGap() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try constant(format, frames: 800, values: [0.5])
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(buffer, hostSeconds: 0)
        // The capture layer keeps the file at pace while the source reconnects.
        for second in 1...40 { try writer.padSilence(throughHostSeconds: Double(second)) }
        try writer.append(buffer, hostSeconds: 40.5)
        try writer.finish()
        let samples = try read(url)
        #expect(samples[0].count == 40 * 8000 + 4000 + 800)
        #expect(abs(samples[0][100] - 0.5) < 0.0001)
        #expect(abs(samples[0][20 * 8000]) < 0.0001)
        #expect(abs(samples[0][40 * 8000 + 4100] - 0.5) < 0.0001)
        #expect(writer.profile.gaps == [RecordingGap(start: 0.1, duration: 40.4)])
    }

    @Test func outageWithoutPeriodicPaddingStillWritesEveryFrame() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        // One minute at 48 kHz exceeds the async ring, so this covers the paced fallback.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try constant(format, frames: 480, values: [0.5])
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(buffer, hostSeconds: 0)
        try writer.append(buffer, hostSeconds: 60)
        try writer.finish()
        let samples = try read(url)
        #expect(samples[0].count == 60 * 48000 + 480)
        #expect(abs(samples[0][60 * 48000 + 100] - 0.5) < 0.0001)
        #expect(writer.profile.gaps == [RecordingGap(start: 0.01, duration: 59.99)])
    }

    @Test func appendOverlappingPaddedSilenceDoesNotDuplicateTime() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(try constant(format, frames: 800, values: [0.5]), hostSeconds: 0)
        try writer.padSilence(throughHostSeconds: 5)
        try writer.padSilence(throughHostSeconds: 4)  // Already past; no-op.
        // Resumed audio starts 0.1 s before the padded end; the overlap is dropped, not appended.
        try writer.append(try constant(format, frames: 1600, values: [0.25]), hostSeconds: 4.9)
        try writer.finish()
        let samples = try read(url)
        #expect(samples[0].count == Int(5.1 * 8000))
        #expect(abs(samples[0][Int(4.95 * 8000)]) < 0.0001)
        #expect(abs(samples[0][Int(5.05 * 8000)] - 0.25) < 0.0001)
        #expect(writer.profile.gaps == [RecordingGap(start: 0.1, duration: 4.9)])
        #expect(writer.capturedFrames == 800 + 800)
    }

    @Test func finishPadsTrailingOutageAndIgnoresLateCallbacks() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try constant(format, frames: 800, values: [0.5])
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(buffer, hostSeconds: 0)
        try writer.finish(throughHostSeconds: 3)
        // Callbacks that arrive after stop are harmless.
        try writer.append(buffer, hostSeconds: 3.5)
        try writer.padSilence(throughHostSeconds: 10)
        #expect(try read(url)[0].count == 3 * 8000)
        #expect(writer.profile.gaps == [RecordingGap(start: 0.1, duration: 2.9)])
    }

    @Test func timelineRejectsInvalidClock() throws {
        #expect(try TimedAudioWriter.targetFrame(hostSeconds: 12.5, epoch: 10, sampleRate: 48000) == 120000)
        #expect(throws: (any Error).self) {
            try TimedAudioWriter.targetFrame(hostSeconds: .nan, epoch: 0, sampleRate: 48000)
        }
    }

    @Test func invalidTimestampIsTerminalButFileStillFinalizes() throws {
        let url = temporaryWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(try constant(format, frames: 800, values: [0.5]), hostSeconds: 0)
        #expect(throws: (any Error).self) { try writer.padSilence(throughHostSeconds: .infinity) }
        #expect(throws: (any Error).self) { try writer.finish() }
        #expect(try read(url)[0].count == 800)
    }

    @Test func olderProfileDecodesAndNewProfileRoundTrips() throws {
        let old = Data(
            #"""
            {"microphoneVoiceProcessing":true,"timeline":"Host clock; missing intervals padded with silence",
             "tracks":[{"filename":"microphone.wav","sampleRate":48000,"channels":1,"voiceProcessed":true}]}
            """#.utf8)
        let decoded = try JSONDecoder().decode(RecordingProfile.self, from: old)
        #expect(decoded.microphoneVoiceProcessing)
        #expect(decoded.voiceProcessingPolicy == nil)
        #expect(decoded.routeChanges.isEmpty)
        #expect(decoded.tracks.first?.gaps == [])
        var current = decoded
        current.voiceProcessingPolicy = .automatic
        current.tracks[0].gaps = [RecordingGap(start: 12, duration: 3.5)]
        current.routeChanges = [
            RecordingRouteChange(
                time: 12, source: "microphone", device: "AirPods", sampleRate: 24000, channels: 1,
                voiceProcessed: false),
            RecordingRouteChange(
                time: 30, source: "microphone", device: "AirPods", sampleRate: 24000, channels: 1,
                voiceProcessed: true, reason: RecordingRouteChange.Reason.echoDetected.rawValue),
        ]
        #expect(try JSONDecoder().decode(RecordingProfile.self, from: JSONEncoder().encode(current)) == current)
        // An unknown future reason still decodes.
        let future = Data(
            #"{"time":1,"source":"microphone","sampleRate":48000,"channels":1,"voiceProcessed":false,"reason":"later"}"#
                .utf8)
        #expect(try JSONDecoder().decode(RecordingRouteChange.self, from: future).reason == "later")
    }

    private func temporaryWAV() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }
    /// A buffer holding one constant value per channel.
    private func constant(_ format: AVAudioFormat, frames: AVAudioFrameCount, values: [Float]) throws
        -> AVAudioPCMBuffer
    {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) { data[channel][frame * buffer.stride] = values[channel] }
        }
        return buffer
    }
    /// Deinterleaved samples per channel.
    private func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let count = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(count, 1)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return (0..<Int(file.processingFormat.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }
}
