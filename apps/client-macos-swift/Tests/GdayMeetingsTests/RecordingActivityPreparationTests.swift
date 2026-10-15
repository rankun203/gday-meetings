import AppKit
import Foundation
import Testing

@testable import GdayMeetings

struct RecordingActivityPreparationTests {
    @Test func geometryKeepsSignalAndQuietBarsSeparate() {
        let input = RecordingActivityGeometryInput(
            bars: [0, 0.5, 1, .nan], size: CGSize(width: 100, height: 20), start: 1)
        let geometry = RecordingActivityGeometry.prepare(input)
        #expect(geometry.step == 25)
        // Rounded-path extrema can differ by floating-point rounding from the source rectangle.
        #expect(abs(geometry.signal.boundingBoxOfPath.minX - 50) < 1e-9)
        #expect(abs(geometry.signal.boundingBoxOfPath.height - 16) < 1e-9)
        #expect(abs(geometry.quiet.boundingBoxOfPath.minX - 25) < 1e-9)
        #expect(abs(geometry.quiet.boundingBoxOfPath.height - 1.5) < 1e-9)
        #expect(geometry.input.start == 1)
    }

    @MainActor
    @Test func rapidSamplesAndResizeCoalesceAndRejectStaleGeometry() async throws {
        let worker = HeldGeometryWorker()
        var applied: [RecordingActivityGeometryInput] = []
        let (stream, continuation) = AsyncStream<RecordingActivityGeometryInput>.makeStream()
        let preparation = RecordingActivityPreparation(prepare: { await worker.prepare($0) }) {
            applied.append($0.input)
            continuation.yield($0.input)
        }
        defer {
            preparation.cancel()
            Task { await worker.finishAll() }
        }
        let first = input(1)
        preparation.submit(first)
        try await worker.waitForRequests(1)
        for revision in 2...100 { preparation.submit(input(revision)) }
        #expect(await worker.inputs.count == 1)
        await worker.finish(0)
        try await worker.waitForRequests(2)
        #expect(applied.isEmpty)
        #expect(await worker.inputs.last == input(100))
        await worker.finish(1)
        #expect(try await nextResult(stream) == input(100))
        #expect(applied == [input(100)])
        // Identical presentation updates must not generate another job.
        preparation.submit(input(100))
        #expect(await worker.inputs.count == 2)
    }

    @MainActor
    @Test func cancellationDoesNotApplyOldGeometryOrOpenAnotherWorkerSlot() async throws {
        let worker = HeldGeometryWorker()
        var applied: [RecordingActivityGeometryInput] = []
        let (stream, continuation) = AsyncStream<RecordingActivityGeometryInput>.makeStream()
        let preparation = RecordingActivityPreparation(prepare: { await worker.prepare($0) }) {
            applied.append($0.input)
            continuation.yield($0.input)
        }
        defer {
            preparation.cancel()
            Task { await worker.finishAll() }
        }
        preparation.submit(input(1))
        try await worker.waitForRequests(1)
        preparation.cancel()
        preparation.submit(input(2))
        #expect(await worker.inputs.count == 1)
        await worker.finish(0)
        try await worker.waitForRequests(2)
        #expect(applied.isEmpty)
        preparation.cancel()
        await worker.finish(1)
        preparation.submit(input(3))
        try await worker.waitForRequests(3)
        await worker.finish(2)
        #expect(try await nextResult(stream) == input(3))
        #expect(applied == [input(3)])
    }

    @MainActor
    @Test func invalidSamplesAndGeometryCompleteOnceWithoutResubmissionLoop() async throws {
        let worker = HeldGeometryWorker()
        let (stream, continuation) = AsyncStream<RecordingActivityGeometryInput>.makeStream()
        let preparation = RecordingActivityPreparation(prepare: { await worker.prepare($0) }) {
            continuation.yield($0.input)
        }
        defer {
            preparation.cancel()
            Task { await worker.finishAll() }
        }
        let invalid = RecordingActivityGeometryInput(
            bars: [.nan, .infinity, -.infinity, 2, -1],
            size: CGSize(width: CGFloat.nan, height: CGFloat.infinity), start: .nan)
        let normalized = RecordingActivityGeometryInput(bars: [0, 0, 0, 1, 0], size: .zero, start: nil)
        #expect(invalid == normalized)
        preparation.submit(invalid)
        try await worker.waitForRequests(1)
        await worker.finish(0)
        #expect(try await nextResult(stream) == normalized)
        for _ in 0..<100 { preparation.submit(invalid) }
        #expect(await worker.inputs.count == 1)
    }

    @MainActor
    @Test func unchangedPresentationDoesNotReplayMeterAndSwitchingDisconnectsOldMeter() {
        let first = RecordingMeterState()
        let second = RecordingMeterState()
        let subscription = RecordingMeterSubscription<Int>()
        var deliveries = 0
        var receivedConfiguration: Int?
        let receive: (RecordingLevels, Int) -> Void = { _, configuration in
            deliveries += 1
            receivedConfiguration = configuration
        }
        subscription.update(meter: first, configuration: 1, receive: receive)
        for _ in 0..<100 { subscription.update(meter: first, configuration: 1, receive: receive) }
        #expect(deliveries == 1)
        first.deliver(RecordingLevels())
        #expect(deliveries == 2)
        subscription.update(meter: first, configuration: 2, receive: receive)
        #expect(deliveries == 3)
        #expect(receivedConfiguration == 2)
        subscription.update(meter: second, configuration: 2, receive: receive)
        #expect(deliveries == 4)
        first.deliver(RecordingLevels())
        #expect(deliveries == 4)
        second.deliver(RecordingLevels())
        #expect(deliveries == 5)
        subscription.cancel()
        second.deliver(RecordingLevels())
        #expect(deliveries == 5)
    }

    private func input(_ revision: Int) -> RecordingActivityGeometryInput {
        RecordingActivityGeometryInput(
            bars: [0, 0.5], size: CGSize(width: 100 + revision, height: 20), start: Double(revision))
    }
}

private actor HeldGeometryWorker {
    private(set) var inputs: [RecordingActivityGeometryInput] = []
    private var jobs: [Int: CheckedContinuation<RecordingActivityGeometry, Never>] = [:]

    func prepare(_ input: RecordingActivityGeometryInput) async -> RecordingActivityGeometry {
        let index = inputs.count
        inputs.append(input)
        return await withCheckedContinuation { continuation in
            jobs[index] = continuation
        }
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while inputs.count < count {
            guard ContinuousClock.now < deadline else { throw WaveformTestTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finishAll() {
        for index in Array(jobs.keys) { finish(index) }
    }

    func finish(_ index: Int) {
        jobs.removeValue(forKey: index)?.resume(returning: RecordingActivityGeometry.prepare(inputs[index]))
    }
}

private struct WaveformTestTimeout: Error {}

private func nextResult(_ stream: AsyncStream<RecordingActivityGeometryInput>) async throws
    -> RecordingActivityGeometryInput?
{
    try await withThrowingTaskGroup(of: RecordingActivityGeometryInput?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw WaveformTestTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
