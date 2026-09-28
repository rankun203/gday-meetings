import AVFoundation
import Combine
import Foundation
import Testing

@testable import GdayMeetings

private actor PlaybackPreparationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor PlaybackAttemptCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

@MainActor
struct MeetingPlaybackTests {
    @Test func animationUsesRateAndStopsOnPauseScrubAndStalledSamples() {
        let progress = PlaybackProgress()
        progress.update(10, at: 100)
        progress.isPlaying = true
        progress.rate = 2
        #expect(abs(progress.animatedTime(at: 100.02) - 10.04) < 0.0001)
        #expect(abs(progress.animatedTime(at: 110) - 10.1) < 0.0001)
        progress.update(10, at: 110)  // A stalled source must not restart interpolation.
        #expect(abs(progress.animatedTime(at: 110) - 10.1) < 0.0001)
        progress.scrub(to: 30)
        #expect(progress.animatedTime(at: 111) == 30)
        progress.scrub(to: nil)
        progress.isPlaying = false
        #expect(progress.animatedTime(at: 112) == 10)
        progress.update(4, at: 113)
        #expect(progress.animatedTime(at: 114) == 4)
        progress.isPlaying = true
        #expect(progress.animatedTime(at: 112) == 4)
    }

    @Test func sharedScrubPositionOverridesTicksAndClearsWithSelection() {
        let playback = MeetingPlayback()
        var controlUpdates = 0
        let subscription = playback.objectWillChange.sink { controlUpdates += 1 }
        playback.progress.update(10)
        playback.progress.scrub(to: 31)
        playback.progress.update(11)  // Playback may continue during a pointer drag.
        #expect(playback.progress.displayedTime == 31)
        #expect(playback.currentTime == 11)
        playback.progress.scrub(to: .nan)
        #expect(playback.progress.displayedTime == 31)
        #expect(controlUpdates == 0)
        playback.progress.scrub(to: nil)
        #expect(playback.progress.displayedTime == 11)
        playback.progress.scrub(to: 40)
        playback.clear()
        #expect(playback.progress.scrubTime == nil)
        #expect(playback.progress.displayedTime == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test func clockPublishesCoherentSeekAndMeetingChanges() {
        let clock = PlaybackProgress()
        let meetingID = UUID()
        clock.setMeeting(meetingID)
        clock.scrub(to: 30)
        var received: [PlaybackProgress.Snapshot] = []
        let subscription = clock.$snapshot.dropFirst().sink { received.append($0) }
        clock.seek(to: 42)
        #expect(received.count == 1)
        #expect(received[0].meetingID == meetingID)
        #expect(received[0].displayedTime == 42)
        #expect(received[0].scrubTime == nil)
        #expect(received[0].seekRevision == 1)
        clock.update(43)
        #expect(clock.snapshot.seekRevision == 1)
        clock.seek(to: 43)
        #expect(clock.snapshot.seekRevision == 2)
        clock.isPlaying = true
        clock.setMeeting(UUID())
        #expect(clock.time == 0)
        #expect(clock.scrubTime == nil)
        #expect(!clock.isPlaying)
        withExtendedLifetime(subscription) {}
    }

    @Test func progressUpdatesDoNotInvalidatePlaybackControls() {
        let playback = MeetingPlayback()
        var controlUpdates = 0
        var clockUpdates = 0
        let controlSubscription = playback.objectWillChange.sink { controlUpdates += 1 }
        let clockSubscription = playback.progress.objectWillChange.sink { clockUpdates += 1 }
        for tick in 1...40 { playback.progress.update(Double(tick) / 4) }
        playback.progress.update(10)  // A repeated position should not redraw either.
        #expect(playback.currentTime == 10)
        #expect(clockUpdates == 40)
        #expect(controlUpdates == 0)
        withExtendedLifetime((controlSubscription, clockSubscription)) {}
    }

    @Test func selectionLoadsPausedAndSwitchingTracksKeepsPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = directory.appendingPathComponent("microphone.wav")
        let system = directory.appendingPathComponent("system.wav")
        try makeSilence(mic, seconds: 2)
        try makeSilence(system, seconds: 3)
        let meeting = Meeting(title: "Fixture meeting", audioFiles: ["microphone.wav", "system.wav"])
        let playback = MeetingPlayback()
        defer { playback.clear() }
        playback.select(meeting: meeting, files: [mic, system])
        await playback.waitForPreparation()
        #expect(playback.errorMessage == nil)
        #expect(playback.hasSelection)
        #expect(!playback.isPlaying)
        #expect(playback.selectedTrack == -1)
        #expect(abs(playback.duration - 3) < 0.01)
        #expect(playback.trackNames == ["Microphone", "System Audio"])
        playback.seek(to: 1.2)
        playback.selectTrack(0)
        await playback.waitForPreparation()
        #expect(playback.selectedTrack == 0)
        #expect(abs(playback.duration - 3) < 0.01)
        await playback.waitForWaveforms()
        #expect(playback.waveforms.compactMap { $0 }.count == 2)
        #expect(playback.mutedTracks == [1])
        playback.toggleMute(0)
        #expect(playback.mutedTracks == [0, 1])
        playback.toggleMute(0)
        #expect(playback.selectedTrack == 0)
        #expect(abs(playback.currentTime - 1.2) < 0.01)
        #expect(!playback.isPlaying)
        playback.seek(to: 500)
        #expect(playback.currentTime == playback.duration)
        playback.skip(by: -15)
        #expect(playback.currentTime == 0)
        var renamed = meeting
        renamed.title = "Renamed"
        playback.reconcile(meetings: [renamed])
        #expect(playback.title == "Renamed")
        #expect(playback.selectedTrack == 0)
        playback.setRecordingActive(true)
        playback.play()
        #expect(!playback.isPlaying)
        #expect(playback.isPlaybackBlocked)
        playback.setRecordingActive(false)
        #expect(!playback.isPlaying)
        playback.reconcile(meetings: [])
        #expect(!playback.hasSelection)
        #expect(playback.duration == 0)
    }

    @Test func stalePreparationCannotReplaceSelectionAndDeletesItsOwnedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let temporary = directory.appendingPathComponent("temporary.wav")
        try makeSilence(source, seconds: 0.2)
        let gate = PlaybackPreparationGate()
        let playback = MeetingPlayback(prepareAudio: { url in
            try FileManager.default.copyItem(at: url, to: temporary)
            await gate.suspend()  // Deliberately ignores cancellation like some framework work.
            return PreparedPlaybackAudio(url: temporary, temporary: true)
        })
        playback.select(meeting: Meeting(title: "Old"), files: [source])
        let oldWork = Task { await playback.waitForPreparation() }
        await gate.waitUntilStarted()
        playback.clear()
        await gate.release()
        await oldWork.value
        #expect(!playback.hasSelection)
        #expect(!playback.isLoading)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedPreparationReportsErrorWithoutStartingPlayback() async throws {
        let playback = MeetingPlayback(prepareAudio: { _ in throw ServiceError("Fixture decode failed") })
        playback.select(meeting: Meeting(title: "Broken"), files: [URL(fileURLWithPath: "/fixture/invalid.opus")])
        await playback.waitForPreparation()
        #expect(playback.errorMessage?.contains("Fixture decode failed") == true)
        #expect(!playback.isLoading)
        #expect(!playback.isPlaying)
        playback.clear()
    }

    @Test func playRetriesFailedSelectionButRecordingPreventsRetry() async {
        let counter = PlaybackAttemptCounter()
        let playback = MeetingPlayback(prepareAudio: { _ in
            let attempt = await counter.next()
            throw ServiceError("Fixture failure \(attempt)")
        })

        let meeting = Meeting(title: "Retry fixture")
        let files = [URL(fileURLWithPath: "/fixture/microphone.opus"), URL(fileURLWithPath: "/fixture/system.opus")]
        playback.select(meeting: meeting, files: files, track: 1)
        await playback.waitForPreparation()
        #expect(await counter.count == 1)
        #expect(playback.errorMessage?.contains("Fixture failure 1") == true)
        playback.setRecordingActive(true)
        playback.togglePlayPause()
        await playback.waitForPreparation()
        #expect(await counter.count == 1)
        #expect(playback.errorMessage?.contains("Fixture failure 1") == true)
        playback.setRecordingActive(false)
        playback.togglePlayPause()
        await playback.waitForPreparation()
        #expect(await counter.count == 2)
        #expect(playback.errorMessage?.contains("Fixture failure 2") == true)
        #expect(playback.meetingID == meeting.id)
        #expect(playback.selectedTrack == 1)
        #expect(!playback.isPlaying)
        #expect(!playback.isLoading)
        playback.clear()
    }

    @Test func playbackReadyBeforeWaveformAndStaleWaveformCannotPublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try makeSilence(source, seconds: 2)
        let gate = PlaybackPreparationGate()
        let playback = MeetingPlayback(readWaveform: { _, _ in
            await gate.suspend()
            return AudioWaveform(duration: 2, peaks: [0.5])
        })
        playback.select(meeting: Meeting(title: "Fixture"), files: [source])
        await playback.waitForPreparation()
        await gate.waitUntilStarted()
        #expect(!playback.isLoading)
        #expect(playback.duration == 2)
        #expect(playback.isLoadingWaveforms)
        let oldWork = Task { await playback.waitForWaveforms() }
        await Task.yield()
        playback.clear()
        await gate.release()
        await oldWork.value
        #expect(playback.waveforms.isEmpty)
        #expect(!playback.isLoadingWaveforms)
    }

    @Test func cachedWaveformAppearsBeforeAudioPreparationCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try makeSilence(source, seconds: 2)
        let envelope = try await WaveformCache.shared.waveform(source: source, readable: source)
        defer { try? FileManager.default.removeItem(at: WaveformCache.shared.entryURL(for: source)) }
        let gate = PlaybackPreparationGate()
        let playback = MeetingPlayback(prepareAudio: { file in
            await gate.suspend()
            return PreparedPlaybackAudio(url: file, temporary: false)
        })
        playback.select(meeting: Meeting(title: "Cached fixture"), files: [source])
        await gate.waitUntilStarted()
        await playback.waitForCachedWaveforms()
        #expect(playback.isLoading)
        #expect(playback.waveforms == [envelope])
        #expect(playback.duration == 2)
        await gate.release()
        await playback.waitForPreparation()
        await playback.waitForWaveforms()
        playback.clear()
    }

    private func makeSilence(_ url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 48000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer)
        file = nil
    }
}
