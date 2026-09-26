import AVFoundation
import AppKit
import Darwin
import SwiftUI
import Testing

@testable import GdayMeetings

/// CPU cost of recording work, measured with synthetic audio and an unshown window.
/// Timing depends on the Mac and its load, so these run only through
/// scripts/measure-recording-cpu.sh (GDAY_PERFORMANCE=1) and print results
/// instead of asserting thresholds.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
struct RecordingPerformanceTests {
    struct Usage {
        var mainThreadSeconds: Double
        var processSeconds: Double
        var wallSeconds: Double
        var mainPercent: Double { 100 * mainThreadSeconds / wallSeconds }
        var processPercent: Double { 100 * processSeconds / wallSeconds }
    }

    static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Runs the main run loop for `seconds`, calling `tick` at `rate` Hz, and
    /// forces the window to lay out and draw as the display cycle would.
    static func run(seconds: Double, rate: Double, window: NSWindow, tick: (Int) -> Void) -> Usage {
        let startWall = ProcessInfo.processInfo.systemUptime
        let startThread = threadCPU()
        let startProcess = processCPU()
        var next = startWall
        var count = 0
        while ProcessInfo.processInfo.systemUptime - startWall < seconds {
            let now = ProcessInfo.processInfo.systemUptime
            if rate > 0, now >= next {
                tick(count)
                count += 1
                next += 1 / rate
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.004))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        return Usage(
            mainThreadSeconds: threadCPU() - startThread, processSeconds: processCPU() - startProcess,
            wallSeconds: ProcessInfo.processInfo.systemUptime - startWall)
    }

    static func levels(_ index: Int) -> RecordingLevels {
        let phase = Double(index)
        return RecordingLevels(
            microphone: RecordingSourceLevel(
                enabled: true, hasSamples: true, rmsDB: -30 + 20 * sin(phase / 3), peakDB: -12),
            system: RecordingSourceLevel(
                enabled: true, hasSamples: true, rmsDB: -25 + 15 * cos(phase / 5), peakDB: -10),
            microphoneStatus: RecordingMicrophoneStatus(canSwitch: true))
    }

    static func report(_ label: String, _ usage: Usage) {
        print(
            String(
                format: "PERF %@: main thread %.1f%%, process %.1f%% of one core over %.1f s", label,
                usage.mainPercent, usage.processPercent, usage.wallSeconds))
    }

    /// The meeting list and the recording meeting's detail, as during a recording.
    @Test func recordingWindowUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        for index in 0..<26 { store.createMeeting(title: "Meeting \(index)") }
        let playback = MeetingPlayback()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LibraryView().environmentObject(store).environmentObject(playback))
        _ = Self.run(seconds: 0.5, rate: 0, window: window) { _ in }
        store.recordingID = store.meetings[0].id
        store.recordingStartedAt = Date()
        _ = Self.run(seconds: 1, rate: 0, window: window) { _ in }

        let idle = Self.run(seconds: 3, rate: 0, window: window) { _ in }
        Self.report("window idle", idle)
        _ = Self.run(seconds: 1, rate: 10, window: window) { index in
            store.recordingMeter.deliver(Self.levels(index))
        }
        let meters = Self.run(seconds: 5, rate: 10, window: window) { index in
            store.recordingMeter.deliver(Self.levels(index))
        }
        Self.report("window with 10 Hz meters", meters)
        let broadUpdates = Self.run(seconds: 5, rate: 10, window: window) { index in
            store.objectWillChange.send()
            store.recordingMeter.deliver(Self.levels(index))
        }
        Self.report("window with 10 Hz store and meter publication", broadUpdates)
        window.close()
    }

    /// Capture-side work for one recording second, run faster than real time:
    /// microphone and system writers, meters, and echo envelopes.
    @Test(arguments: [false, true]) func captureProcessing(convertMicrophone: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-perf-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        // A rebuilt engine on another device (for example 44.1 kHz stereo) is converted to the track format.
        let device =
            convertMicrophone
            ? try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)) : track
        let system = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let microphoneWriter = try TimedAudioWriter(
            url: directory.appendingPathComponent("microphone.wav"), format: track, epoch: 0)
        let systemWriter = try TimedAudioWriter(
            url: directory.appendingPathComponent("system.wav"), format: system, epoch: 0)
        let microphoneFrames = AVAudioFrameCount(device.sampleRate > 45000 ? 1024 : 941)
        let microphoneBuffer = try #require(AVAudioPCMBuffer(pcmFormat: device, frameCapacity: microphoneFrames))
        microphoneBuffer.frameLength = microphoneFrames
        let systemBuffer = try #require(AVAudioPCMBuffer(pcmFormat: system, frameCapacity: 512))
        systemBuffer.frameLength = 512
        for buffer in [microphoneBuffer, systemBuffer] {
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let samples = audio.mData!.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(audio.mDataByteSize) / 4 { samples[index] = Float(sin(Double(index) / 7)) * 0.2 }
            }
        }
        var echo = EchoDetector()
        let audioSeconds = 60.0
        let start = Self.processCPU()
        let wall = ProcessInfo.processInfo.systemUptime
        var microphoneTime = 0.0
        var systemTime = 0.0
        var nextEvaluation = 1.0
        var nextDrain = 0.1
        while microphoneTime < audioSeconds || systemTime < audioSeconds {
            if microphoneTime <= systemTime {
                try microphoneWriter.append(microphoneBuffer, hostSeconds: microphoneTime)
                let level = RecordingSourceLevel.measure(microphoneBuffer)
                let duration = Double(microphoneFrames) / device.sampleRate
                echo.addMicrophone(
                    meanSquare: pow(10, level.rmsDB / 10), hostTime: microphoneTime, duration: duration)
                microphoneTime += duration
            }
            else {
                try systemWriter.append(systemBuffer, hostSeconds: systemTime)
                let level = RecordingSourceLevel.measure(systemBuffer)
                echo.addSystem(meanSquare: pow(10, level.rmsDB / 10), hostTime: systemTime, duration: 512 / 48000)
                systemTime += 512 / 48000
            }
            // The async writer has a bounded ring. Leave drain time every tenth
            // of a recorded second instead of overflowing it in a faster-than-real-time test.
            if min(microphoneTime, systemTime) >= nextDrain {
                Thread.sleep(forTimeInterval: 0.002)
                nextDrain += 0.1
            }
            if min(microphoneTime, systemTime) >= nextEvaluation {
                _ = echo.evaluate()
                nextEvaluation += 1
            }
        }
        try microphoneWriter.finish()
        try systemWriter.finish()
        let cpu = Self.processCPU() - start
        print(
            String(
                format: "PERF capture (%@): %.2f ms CPU per recorded second (%.2f%% of one core), %.2f s wall",
                convertMicrophone ? "microphone converted" : "native formats", 1000 * cpu / audioSeconds,
                100 * cpu / audioSeconds, ProcessInfo.processInfo.systemUptime - wall))
    }

    /// Wake-up cost of the system-audio drain timer while no audio is queued.
    @Test func drainTimerWakeups() {
        let queue = DispatchQueue(label: "perf.drain")
        for interval in [10, 20] {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(interval), leeway: .milliseconds(2))
            timer.setEventHandler {}
            let start = Self.processCPU()
            timer.resume()
            Thread.sleep(forTimeInterval: 3)
            timer.cancel()
            print(
                String(
                    format: "PERF %d ms drain timer: %.2f%% of one core", interval,
                    100 * (Self.processCPU() - start) / 3))
        }
    }
}
