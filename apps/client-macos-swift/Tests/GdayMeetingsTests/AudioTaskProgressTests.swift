import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct AudioTaskProgressTests {
    @Test func sequentialTracksCountBothAudioDurations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        var files: [URL] = []
        for seconds in [1, 2] {
            let url = directory.appendingPathComponent("track-\(seconds).wav")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 16000)))
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            files.append(url)
        }
        let durations = try AudioTaskProgress.durations(files)
        #expect(durations == [1, 2])
        #expect(durations.reduce(0, +) == 3)
    }

    @Test @MainActor func remoteQueueAndProcessingRemainDistinct() throws {
        guard case .queued = try RunPodProvider.parseStatus(["status": "IN_QUEUE"]) else {
            Issue.record("The queued state was lost")
            return
        }
        guard case .processing = try RunPodProvider.parseStatus(["status": "IN_PROGRESS"]) else {
            Issue.record("The processing state was lost")
            return
        }
        guard case .processing = try GdayServerService.parseTask(["status": "RUNNING", "outputs": []]) else {
            Issue.record("The server processing state was lost")
            return
        }
        guard case .pending = try GdayServerService.parseTask(["status": "PENDING", "outputs": []]) else {
            Issue.record("Unknown work must remain indeterminate")
            return
        }
    }

    @Test func progressChannelDrainsBeforeTheNextPhase() async {
        let receiver = AudioProgressReceiver()
        let channel = AudioProgressChannel { update in await receiver.append(update.details) }
        for value in 0...100 {
            channel.continuation.yield(.init(phase: "Finding speech", completed: Double(value), total: 100))
        }
        await channel.finish()
        let updates = await receiver.updates
        #expect(updates.last?.completed == 100)
        #expect(updates.map { $0.completed ?? 0 } == updates.map { $0.completed ?? 0 }.sorted())
    }
}

private actor AudioProgressReceiver {
    var updates: [TaskProgress] = []
    func append(_ update: TaskProgress) { updates.append(update) }
}

extension AudioTaskProgressTests {
    @MainActor @Test func staleAndCancelledAudioSamplesAreNotLearned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = UUID()
        let key = TaskPerformanceKey(operation: "test-transcription", provider: "example", model: UUID().uuidString)
        let measurement = AudioPerformanceMeasurement()
        await measurement.include(
            .init(.init(phase: "Transcribing"), processedAudioSeconds: 120, processingSeconds: 30))
        #expect(store.beginJob(.transcription, .meeting(id), progress: "Preparing"))
        let oldAttempt = try #require(store.jobProgressAttemptID(.transcription, .meeting(id)))
        store.endJob(.transcription, .meeting(id))
        #expect(store.beginJob(.transcription, .meeting(id), progress: "Preparing again"))
        await store.commitAudioPerformance(
            measurement, kind: .transcription, meetingID: id, key: key, attemptID: oldAttempt)
        #expect(store.taskProgressEstimate(key: key, remainingUnits: 60) == nil)
        store.reportAudioTaskProgress(
            .init(.init(phase: "Old transcription", completed: 120, total: 120, unit: "audio seconds")),
            kind: .transcription, meetingID: id, key: key, attemptID: oldAttempt)
        #expect(store.backgroundJobs.first?.progress == "Preparing again")
        let currentAttempt = try #require(store.jobProgressAttemptID(.transcription, .meeting(id)))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await store.commitAudioPerformance(
                measurement, kind: .transcription, meetingID: id, key: key, attemptID: currentAttempt)
        }
        await cancelled.value
        #expect(store.taskProgressEstimate(key: key, remainingUnits: 60) == nil)
        await store.commitAudioPerformance(
            measurement, kind: .transcription, meetingID: id, key: key, attemptID: currentAttempt)
        #expect(store.taskProgressEstimate(key: key, remainingUnits: 60) == 15)
        store.endJob(.transcription, .meeting(id))
    }
}
