import Foundation

/// One in-flight save and one replacement snapshot keep slow storage off the main actor.
@MainActor
final class LiveTranscriptCheckpointWriter {
    struct Snapshot: Sendable {
        let draft: LiveTranscriptDraft
        let directory: URL
        let report: @MainActor @Sendable (String?) -> Void
    }
    private var pending: Snapshot?
    private var worker: Task<Void, Never>?
    private let save: @Sendable (LiveTranscriptDraft, URL) throws -> Void

    init(save: @escaping @Sendable (LiveTranscriptDraft, URL) throws -> Void = { try $0.save(at: $1) }) {
        self.save = save
    }

    func submit(
        _ draft: LiveTranscriptDraft, at directory: URL, report: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        pending = Snapshot(draft: draft, directory: directory, report: report)
        guard worker == nil else { return }
        worker = Task {
            while let snapshot = pending {
                pending = nil
                let save = self.save
                let issue = await Task.detached(priority: .utility) {
                    do {
                        try save(snapshot.draft, snapshot.directory)
                        return Optional<String>.none
                    }
                    catch {
                        return "Couldn’t save the live draft. Recording continues. Check available storage."
                    }
                }.value
                snapshot.report(issue)
            }
            worker = nil
        }
    }

    func flush() async {
        while let worker { await worker.value }
    }
}

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
