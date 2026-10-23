import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct LiveAudioBacklogTests {
    private func buffer(_ value: Float, frames: UInt32 = 8000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }

    @Test(.timeLimit(.minutes(1)))
    func readinessPreservesPreparationAudioAndBoundsSubsequentLivePackets() async throws {
        let backlog = LiveAudioBacklog()
        defer { backlog.discard() }
        for index in 0..<8 { backlog.append(buffer(Float(index)), start: Double(index)) }
        backlog.finishPreparation()
        for index in 8..<12 { backlog.append(buffer(Float(index)), start: Double(index)) }
        for index in 0..<7 {
            let packet = try #require(await backlog.next())
            #expect(packet.start == Double(index))
            #expect(packet.buffer.floatChannelData![0][4000] == Float(index))
        }
        // With one second left, capture can accept one second and rejects excess.
        backlog.append(buffer(12), start: 12)
        backlog.append(buffer(13), start: 13)
        backlog.finish()
        let lastPreparation = try #require(await backlog.next())
        let live = try #require(await backlog.next())
        #expect(lastPreparation.start == 7)
        #expect(live.start == 12)
        #expect(await backlog.next() == nil)
        #expect(backlog.takeDroppedRanges() == [LiveAudioLoss(start: 8, end: 12), LiveAudioLoss(start: 13, end: 14)])
    }

    @Test(.timeLimit(.minutes(1)))
    func staleCleanupPreservesAnotherActiveBacklogAndUnleasedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let activeDirectory = root.appendingPathComponent("gday-live-\(UUID())")
        let active = LiveAudioBacklog(directory: activeDirectory)
        defer { active.discard() }
        for index in 0..<4 { active.append(buffer(Float(index)), start: Double(index)) }
        _ = try #require(await active.next())
        let orphan = root.appendingPathComponent("gday-live-\(UUID())")
        let unleased = root.appendingPathComponent("gday-live-\(UUID())")
        let fresh = root.appendingPathComponent("gday-live-\(UUID())")
        let unrelated = root.appendingPathComponent("other-audio")
        for directory in [orphan, unleased, fresh, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if directory != unleased { try Data().write(to: directory.appendingPathComponent("owner.lock")) }
        }
        let old = Date().addingTimeInterval(-120)
        for directory in [activeDirectory, orphan, unleased, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }
        LiveAudioBacklog.cleanupStaleBacklogs(in: root)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        for directory in [activeDirectory, unleased, fresh, unrelated] {
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
        let retained = try #require(await active.next())
        #expect(retained.start == 1)
        active.finish()
        while await active.next() != nil {}
        #expect(!FileManager.default.fileExists(atPath: activeDirectory.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedConsumptionReplaysBeyondMemoryBudgetWithoutLosingSamples() async throws {
        let queue = LiveAudioQueue(bufferDuringPreparation: true)
        for index in 0..<8 { queue.append(buffer(Float(index)), start: Double(index)) }
        queue.finish()
        var index = 0
        for await packet in queue.stream {
            #expect(packet.start == Double(index))
            #expect(packet.duration == 1)
            #expect(packet.buffer.frameLength == 8000)
            #expect(packet.buffer.floatChannelData![0][0] == Float(index))
            #expect(packet.buffer.floatChannelData![0][7999] == Float(index))
            queue.consumed(packet)
            index += 1
        }
        #expect(index == 8)
        #expect(queue.takeDroppedRanges().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func diskCatchUpReturnsToLiveDeliveryAndRemovesChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backlog = LiveAudioBacklog(directory: directory, chunkBytes: 40_000)
        defer { backlog.discard() }
        for index in 0..<8 { backlog.append(buffer(Float(index)), start: Double(index)) }
        for index in 0..<8 {
            let packet = try #require(await backlog.next())
            #expect(packet.start == Double(index))
            #expect(packet.buffer.floatChannelData![0][4000] == Float(index))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // The same consumer continues after every disk chunk has been deleted.
        backlog.append(buffer(8), start: 8)
        let live = try #require(await backlog.next())
        #expect(live.start == 8)
        #expect(live.buffer.floatChannelData![0][4000] == 8)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        backlog.finish()
        #expect(await backlog.next() == nil)
        #expect(backlog.takeDroppedRanges().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func discardClearsDiskAndEndsPendingReaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backlog = LiveAudioBacklog(directory: directory)
        for index in 0..<8 { backlog.append(buffer(Float(index)), start: Double(index)) }
        backlog.discard()
        #expect(await backlog.next() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let waiting = LiveAudioBacklog()
        let task = Task { await waiting.next() }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func diskFailurePreservesEarlierAudioAndReportsLostIntervals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backlog = LiveAudioBacklog(directory: directory)
        for index in 0..<5 { backlog.append(buffer(Float(index)), start: Double(index)) }
        backlog.finish()
        let first = try #require(await backlog.next())
        let second = try #require(await backlog.next())
        #expect(first.start == 0)
        #expect(second.start == 1)
        #expect(await backlog.next() == nil)
        #expect(backlog.takeDroppedRanges() == [LiveAudioLoss(start: 2, end: 5)])
        #expect(backlog.failureDescription == "Couldn’t buffer audio for live transcription. Recording continues.")
    }

    @Test(.timeLimit(.minutes(1)))
    func producerMemoryLimitReportsLossInsteadOfRetainingOversizedPacket() async {
        let backlog = LiveAudioBacklog(maximumPendingBytes: 100)
        backlog.append(buffer(1), start: 3)
        backlog.finish()
        #expect(await backlog.next() == nil)
        #expect(backlog.takeDroppedRanges() == [LiveAudioLoss(start: 3, end: 4)])
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultQueueRetainsItsTwoSecondLimit() async {
        let queue = LiveAudioQueue()
        for index in 0..<4 { queue.append(buffer(Float(index)), start: Double(index)) }
        queue.finish()
        var starts: [Double] = []
        for await packet in queue.stream {
            starts.append(packet.start)
            queue.consumed(packet)
        }
        #expect(starts == [0, 1])
        #expect(queue.takeDroppedRanges() == [LiveAudioLoss(start: 2, end: 4)])
    }
}
