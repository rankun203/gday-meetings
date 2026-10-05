import Foundation
import Testing

@testable import GdayMeetings

private actor DelayedTranscriptHistoryRead {
    private var first: CheckedContinuation<TranscriptHistorySnapshot, Never>?
    var started: Bool { first != nil }
    func read(_ key: TranscriptHistoryReadKey) async -> TranscriptHistorySnapshot {
        if key.source == nil {
            return await withCheckedContinuation { first = $0 }
        }
        return .init(failure: "Current result")
    }
    func release() {
        first?.resume(returning: .init(failure: "Earlier result"))
        first = nil
    }
}

@MainActor struct TranscriptHistoryReaderTests {
    @Test func slowEarlierRequestCannotReplaceLatestSource() async throws {
        let gate = DelayedTranscriptHistoryRead()
        let reader = TranscriptHistoryReader { await gate.read($0) }
        var key = TranscriptHistoryReadKey(directory: FileManager.default.temporaryDirectory, meetingID: UUID())
        let firstKey = key
        let earlier = Task { await reader.load(firstKey) }
        while await gate.started == false { await Task.yield() }
        key.source = .init(id: UUID(), providerName: "Example", generatedAt: Date())
        let current = await reader.load(key)
        #expect(current?.failure == "Current result")
        await gate.release()
        #expect(await earlier.value == nil)
    }

    @Test func cancelledRequestDoesNotPublish() async {
        let gate = DelayedTranscriptHistoryRead()
        let reader = TranscriptHistoryReader { await gate.read($0) }
        let key = TranscriptHistoryReadKey(directory: FileManager.default.temporaryDirectory, meetingID: UUID())
        let task = Task { await reader.load(key) }
        while await gate.started == false { await Task.yield() }
        task.cancel()
        await gate.release()
        #expect(await task.value == nil)
    }
}
