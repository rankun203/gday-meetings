import AVFoundation
import Foundation
import OpusFileBridge
import Testing

@testable import GdayMeetings

private final class FailingTrackReader: StreamingAudioReading {
    let totalFrames: Int64 = 96000
    let failure: String
    private var reads = 0
    init(failure: String) { self.failure = failure }
    func seek(frame: Int64) throws {
        if failure == "seek" { throw ServiceError("Synthetic seek failure") }
    }
    func read(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) throws {
        reads += 1
        if failure == "read", reads > 12 { throw ServiceError("Synthetic read failure") }
        buffer.frameLength = frames
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 0.25, count: Int(frames))
        }
    }
}

private final class SeekBoundaryReader: StreamingAudioReading {
    let totalFrames: Int64 = 192000
    private var position: Int64 = 0
    func seek(frame: Int64) throws { position = frame }
    func read(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) throws {
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = position + Int64(frame) < 96000 ? 0.25 : 0
            }
        }
        position += Int64(frames)
    }
}

struct StreamingPlaybackTests {
    @Test func preparedSeekClearsPreviousAudioAndHonorsLaterPause() async throws {
        let player = StreamingPlayback(manualRendering: true, openReader: { _ in SeekBoundaryReader() })
        defer { player.close() }
        _ = try await player.prepare(files: [URL(fileURLWithPath: "/synthetic")])
        try await player.play(rate: 1)
        for _ in 0..<8 { _ = try await player.renderOffline(frames: 4096) }
        let completions = AsyncStream<Result<Void, Error>>.makeStream()
        let revision = UUID()
        player.requestSeek(to: 2.5, revision: revision, resumeRate: 1) { completions.continuation.yield($0) }
        var iterator = completions.stream.makeAsyncIterator()
        try #require(await iterator.next()).get()
        // The first block after a seek must contain no time-pitch history from
        // the audible source interval, even though the graph stays prepared.
        for _ in 0..<4 {
            let audio = try await player.renderOffline(frames: 4096)
            #expect((0..<Int(audio.frameLength)).allSatisfy { abs(audio.floatChannelData![0][$0]) < 0.00001 })
        }
        let updates = AsyncStream<StreamingPlayback.Snapshot>.makeStream()
        player.onUpdate = { updates.continuation.yield($0) }
        player.requestSeek(to: 0.5, revision: UUID(), resumeRate: 1) { completions.continuation.yield($0) }
        player.pause()
        try #require(await iterator.next()).get()
        // An explicit pause queued after seek/resume is the final transport
        // action; completion never schedules a second Play through the UI.
        await player.shutdown()
        updates.continuation.finish()
        var last: StreamingPlayback.Snapshot?
        for await update in updates.stream { last = update }
        #expect(last?.playing == false)
        completions.continuation.finish()
    }

    @MainActor @Test func queuedSeekCompletesWhileMainActorIsBusy() async throws {
        let player = StreamingPlayback(manualRendering: true, openReader: { _ in SeekBoundaryReader() })
        defer { player.close() }
        _ = try await player.prepare(files: [URL(fileURLWithPath: "/synthetic")])
        let completed = DispatchSemaphore(value: 0)
        let results = AsyncStream<Result<Void, Error>>.makeStream()
        // Deliberately keep this actor occupied: the transport must enqueue
        // synchronously and finish seeking/resuming without a UI round trip.
        player.requestSeek(to: 1, revision: UUID(), resumeRate: 1) {
            results.continuation.yield($0)
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 2) == .success)
        results.continuation.finish()
        var iterator = results.stream.makeAsyncIterator()
        try #require(await iterator.next()).get()
    }

    @Test(arguments: ["open", "seek", "read"])
    func trackFailureDoesNotStopOrAttenuateRemainingAudio(failure: String) async throws {
        let player = StreamingPlayback(
            manualRendering: true,
            openReader: { url in
                if url.lastPathComponent == "failed" {
                    if failure == "open" { throw ServiceError("Synthetic open failure") }
                    return FailingTrackReader(failure: failure)
                }
                return FailingTrackReader(failure: "none")
            })
        defer { player.close() }
        let updates = AsyncStream<StreamingPlayback.Snapshot>.makeStream()
        player.onUpdate = { updates.continuation.yield($0) }
        let duration = try await player.prepare(files: [URL(fileURLWithPath: "/failed"), URL(fileURLWithPath: "/good")])
        #expect(duration == 2)
        try await player.seek(to: 0.2, revision: UUID())
        try await player.play(rate: 1)
        var audio: AVAudioPCMBuffer?
        for _ in 0..<10 { audio = try await player.renderOffline(frames: 4096) }
        let rendered = try #require(audio)
        let average =
            (0..<Int(rendered.frameLength)).reduce(Float(0)) { $0 + abs(rendered.floatChannelData![0][$1]) }
            / Float(rendered.frameLength)
        #expect(abs(average - 0.25) < 0.01)
        // Force a snapshot after any failure discovered by offline refill.
        try await player.seek(to: 1, revision: UUID())
        updates.continuation.finish()
        var last: StreamingPlayback.Snapshot?
        for await snapshot in updates.stream { last = snapshot }
        #expect(last?.trackErrors[0] != nil)
        #expect(last?.trackErrors[1] == nil)
        #expect(last?.error == nil)
        // Original index 1 still controls the surviving track.
        player.setMuted([1])
        try await player.play(rate: 1)
        for _ in 0..<8 { audio = try await player.renderOffline(frames: 4096) }
        #expect((0..<Int(audio!.frameLength)).allSatisfy { abs(audio!.floatChannelData![0][$0]) < 0.00001 })
    }

    @Test func allTracksFailWithVisibleError() async throws {
        let player = StreamingPlayback(
            manualRendering: true,
            openReader: { _ in
                throw ServiceError("Synthetic invalid audio")
            })
        defer { player.close() }
        await #expect(throws: ServiceError.self) {
            _ = try await player.prepare(files: [URL(fileURLWithPath: "/one"), URL(fileURLWithPath: "/two")])
        }
    }

    @Test func excerptNeverRendersSpeechBeyondItsEndAndNormalSeekRestoresFullAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = StreamingAudioReader.format
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        audio.frameLength = 48000
        for channel in 0..<2 {
            for frame in 0..<48000 {
                audio.floatChannelData![channel][frame] =
                    frame < 12000 ? 0 : Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.3
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: audio)
        }
        let player = StreamingPlayback(manualRendering: true)
        defer { player.close() }
        _ = try await player.prepare(files: [url])
        try await player.seek(to: 0, revision: UUID(), end: 0.25)
        try await player.play(rate: 1)
        for _ in 0..<16 {
            let rendered = try await player.renderOffline(frames: 4096)
            #expect((0..<Int(rendered.frameLength)).allSatisfy { abs(rendered.floatChannelData![0][$0]) < 0.00001 })
        }
        try await player.seek(to: 0.25, revision: UUID())
        try await player.play(rate: 1)
        var energy: Float = 0
        for _ in 0..<8 {
            let rendered = try await player.renderOffline(frames: 4096)
            for frame in 0..<Int(rendered.frameLength) { energy += abs(rendered.floatChannelData![0][frame]) }
        }
        #expect(energy > 100)
    }

    @Test(arguments: [false, true])
    func routeChangeOnlyReportsInterruptedPlayback(wasPlaying: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try OpusFixture.all[0].data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = StreamingPlayback(manualRendering: true)
        _ = try await player.prepare(files: [url])
        if wasPlaying { try await player.play(rate: 1) }
        let updates = AsyncStream<StreamingPlayback.Snapshot>.makeStream()
        player.onUpdate = { updates.continuation.yield($0) }
        player.audioConfigurationChanged()
        var iterator = updates.stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.requiresReload)
        #expect(!snapshot.playing)
        #expect((snapshot.error != nil) == wasPlaying)
        await player.shutdown()
        updates.continuation.finish()
    }

    @Test(arguments: OpusFixture.all) func opusIncrementalDecodeSeekAndEnd(fixture: OpusFixture) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try fixture.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try OpusFileDecoder(url)
        #expect(decoder.totalFrames == 4081)
        #expect(decoder.channels == fixture.channels)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 512))
        var left: [Float] = []
        var right: [Float] = []
        repeat {
            try decoder.read(into: buffer, frames: 512)
            left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
        } while buffer.frameLength > 0
        #expect(left.count == 4081)
        #expect(left.reduce(0) { $0 + abs($1) } > 1)
        if fixture.channels == 1 { #expect(left == right) }
        try decoder.seek(frame: 1024)
        try decoder.read(into: buffer, frames: 512)
        #expect(decoder.position == 1536)
        let difference = (0..<512).map { abs(left[1024 + $0] - buffer.floatChannelData![0][$0]) }.max() ?? 0
        #expect(difference < 0.002)
        try decoder.seek(frame: decoder.totalFrames)
        try decoder.read(into: buffer, frames: 512)
        #expect(buffer.frameLength == 0)
        try decoder.seek(frame: 0)
        try decoder.read(into: buffer, frames: 512)
        #expect(buffer.frameLength == 512)
    }

    @Test func ringMixMuteWrapAndUnderrunShareOneClock() throws {
        let ring = try #require(gday_playback_create(2, 8))
        defer { gday_playback_destroy(ring) }
        let first = [Float](repeating: 0.25, count: 8)
        let second = [Float](repeating: 0.75, count: 8)
        func write(_ count: UInt32) {
            first.withUnsafeBufferPointer { gday_playback_write_track(ring, 0, $0.baseAddress, $0.baseAddress, count) }
            second.withUnsafeBufferPointer { gday_playback_write_track(ring, 1, $0.baseAddress, $0.baseAddress, count) }
            gday_playback_commit(ring, count)
        }
        var left = [Float](repeating: 0, count: 8)
        var right = left
        func render(_ count: UInt32) -> UInt32 {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    gday_playback_render(ring, l.baseAddress, r.baseAddress, count)
                }
            }
        }
        write(8)
        #expect(render(5) == 5)
        #expect(Array(left.prefix(5)) == [Float](repeating: 0.5, count: 5))
        gday_playback_set_audible(ring, 1)
        write(5)  // wraps across the end of the fixed ring
        #expect(render(8) == 8)
        #expect(left == [Float](repeating: 0.25, count: 8))
        #expect(gday_playback_consumed(ring) == 13)
        #expect(render(8) == 0)
        #expect(left == [Float](repeating: 0, count: 8))
        #expect(gday_playback_consumed(ring) == 13)  // silence does not advance media time
        #expect(gday_playback_underruns(ring) == 1)
        gday_playback_reset(ring)
        #expect(gday_playback_consumed(ring) == 0)
        #expect(gday_playback_free(ring) == 8)
    }

    @Test func tenHourOpusOpensAndSeeksWithoutReadingOrDecodingWholeFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        defer { try? FileManager.default.removeItem(at: url) }
        // Standard 20 ms Opus silence packet; 250 packets per Ogg page (5 s).
        let packets = [Data](repeating: Data([0xF8, 0xFF, 0xFE]), count: 250)
        let writer = try OggOpusWriter(destination: url, channels: 1, preSkip: 0, inputSampleRate: 48000)
        for page in 1...7200 { try writer.writeAudio(packets, granule: Int64(page) * 240000, final: page == 7200) }
        try writer.close()
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let clock = ContinuousClock()
        let start = clock.now
        let decoder = try OpusFileDecoder(url)
        #expect(decoder.totalFrames == 48000 * 36000)
        #expect(decoder.position == 0)
        #expect(decoder.bytesRead < UInt64(size / 4))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 4096))
        try decoder.read(into: buffer, frames: 4096)
        #expect(decoder.position == 4096)
        try decoder.seek(frame: 48000 * 35990)
        try decoder.read(into: buffer, frames: 4096)
        #expect(decoder.position == 48000 * 35990 + 4096)
        #expect(decoder.bytesRead < UInt64(size / 2))
        print(
            "10h Opus open + first block + seek near end: \(start.duration(to: clock.now)); read \(decoder.bytesRead)/\(size) bytes"
        )
        let waveformStart = clock.now
        let waveform = try await AudioWaveform.read(url)
        #expect(waveform.duration == 36000)
        #expect(waveform.peaks.count == 1200)
        #expect(waveform.peaks.allSatisfy { $0 < 0.00001 })
        print("10h Opus sampled waveform: \(waveformStart.duration(to: clock.now))")
    }

    @Test func engineRendersOpusAndNativeTrackOfflineWithoutTemporaryAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let opus = directory.appendingPathComponent("system.opus")
        try OpusFixture.all[0].data.write(to: opus)
        let native = directory.appendingPathComponent("microphone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        source.frameLength = 44100
        for frame in 0..<44100 {
            source.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100)) * 0.25
        }
        do {
            let file = try AVAudioFile(forWriting: native, settings: format.settings)
            try file.write(from: source)
        }
        let player = StreamingPlayback(manualRendering: true)
        defer { player.close() }
        let duration = try await player.prepare(files: [opus, native])
        #expect(abs(duration - 1) < 0.0001)
        try await player.seek(to: 0, revision: UUID())
        try await player.play(rate: 1)
        var energy: Float = 0
        for _ in 0..<12 {
            let audio = try await player.renderOffline(frames: 4096)
            for frame in 0..<Int(audio.frameLength) { energy += abs(audio.floatChannelData![0][frame]) }
        }
        #expect(energy > 100)
        player.pause()
        try await player.seek(to: 0.5, revision: UUID())
        player.setMuted([0, 1])
        try await player.play(rate: 2)
        // Allow the time-pitch unit's history to drain after the mute.
        var final: AVAudioPCMBuffer?
        for _ in 0..<5 { final = try await player.renderOffline(frames: 4096) }
        #expect((0..<Int(final!.frameLength)).allSatisfy { abs(final!.floatChannelData![0][$0]) < 0.00001 })
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
                "microphone.wav", "system.opus",
            ])
    }
}
