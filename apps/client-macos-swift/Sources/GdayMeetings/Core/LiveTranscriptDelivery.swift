import Foundation

/// Audio producers never await UI delivery. One worker drains a bounded set of ranges.
final class LiveTranscriptGapReporter: @unchecked Sendable {
    static let uncertainReason = "Live transcription coverage is uncertain while reporting catches up."
    private let lock = NSLock()
    private var pending: [LiveTranscriptGap] = []
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    private let overflowReason: String
    private let deliver: @Sendable (LiveTranscriptGap) async -> Void

    init(
        limit: Int = 64, uncertainReason: String = LiveTranscriptGapReporter.uncertainReason,
        deliver: @escaping @Sendable (LiveTranscriptGap) async -> Void
    ) {
        self.limit = max(2, limit)
        overflowReason = uncertainReason
        self.deliver = deliver
    }

    func append(_ gap: LiveTranscriptGap) {
        guard gap.start.isFinite, gap.end.isFinite, gap.start >= 0, gap.end > gap.start else { return }
        lock.lock()
        if let index = pending.lastIndex(where: {
            $0.source == gap.source && $0.reason == gap.reason
                && $0.end >= gap.start - LiveAudioInputTimeline.gapTolerance
                && gap.end >= $0.start - LiveAudioInputTimeline.gapTolerance
        }) {
            pending[index].start = min(pending[index].start, gap.start)
            pending[index].end = max(pending[index].end, gap.end)
        }
        else if pending.count < limit {
            pending.append(gap)
        }
        else if let index = pending.lastIndex(where: { $0.source == gap.source }) {
            // Never silently discard a range. Under prolonged UI starvation, mark
            // a conservative span as uncertain; the recording clock is unchanged.
            pending[index] = LiveTranscriptGap(
                source: gap.source, start: min(pending[index].start, gap.start),
                end: max(pending[index].end, gap.end), reason: overflowReason)
        }
        else {
            // Both sources retain coverage even when the other source filled the mailbox.
            // With two possible sources and no matching source, all pending entries share one source.
            pending[0] = LiveTranscriptGap(
                source: pending[0].source, start: min(pending[0].start, pending[1].start),
                end: max(pending[0].end, pending[1].end), reason: overflowReason)
            pending.remove(at: 1)
            pending.append(gap)
        }
        let start = !running
        running = true
        lock.unlock()
        if start { Task { await drain() } }
    }

    private func next() -> LiveTranscriptGap? {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { return pending.removeFirst() }
        running = false
        let finished = waiters
        waiters = []
        finished.forEach { $0.resume() }
        return nil
    }

    private func drain() async {
        while let gap = next() { await deliver(gap) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if running {
                waiters.append(continuation)
            }
            else {
                continuation.resume()
            }
            lock.unlock()
        }
    }
}
