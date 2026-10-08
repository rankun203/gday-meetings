import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LiveObservationReviewMailboxTests {
    private func sample(_ id: String) -> LiveObservationReviewAssignment {
        .init(
            sample: .init(
                id: id, source: "microphone", localSpeakerID: UUID().uuidString, start: 0, end: 3,
                embedding: .init(
                    type: .init(
                        modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                        dimension: 2, normalization: "unitL2"), values: [1, 0])),
            meetingSpeakerID: UUID())
    }
    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw MeetingError.message("Mailbox did not advance") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func slowWriteCoalescesIntermediateSnapshotsAndDrainsLatest() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var written: [[String]] = []
        let mailbox = LiveObservationReviewMailbox { snapshot in
            written.append(snapshot.map { $0.sample.id })
            if written.count == 1 { await withCheckedContinuation { gate = $0 } }
            return true
        }
        mailbox.enqueue([sample("first")])
        try await wait { gate != nil }
        for index in 0..<100 { mailbox.enqueue([sample("intermediate-\(index)")]) }
        mailbox.enqueue([sample("latest")])
        #expect(written == [["first"]])
        gate?.resume()
        await mailbox.drain()
        #expect(written == [["first"], ["latest"]])
        #expect(!mailbox.failed)
    }

    @Test func failureIsReportedAndFinalSuccessRecovers() async {
        var successful = false
        var reports: [Bool] = []
        let mailbox = LiveObservationReviewMailbox(write: { _ in successful }, report: { reports.append($0) })
        mailbox.enqueue([sample("failed")])
        await mailbox.drain()
        #expect(mailbox.failed)
        successful = true
        mailbox.enqueue([])
        await mailbox.drain()
        #expect(!mailbox.failed)
        #expect(reports == [false, true])
    }

    @Test func cancellationDoesNotPublishStaleCompletionOrPendingSnapshot() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var writes = 0
        var reports = 0
        let mailbox = LiveObservationReviewMailbox(
            write: { _ in
                writes += 1
                await withCheckedContinuation { gate = $0 }
                return true
            }, report: { _ in reports += 1 })
        mailbox.enqueue([sample("old")])
        try await wait { gate != nil }
        mailbox.enqueue([sample("pending")])
        mailbox.cancel()
        gate?.resume()
        await mailbox.drain()
        #expect(writes == 1 && reports == 0)
    }
}
