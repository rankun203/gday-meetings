import Foundation

/// Representative snapshots replace each other. Slow library I/O must never
/// serialize acoustic inference or retain an unbounded queue of old profiles.
@MainActor final class LiveObservationReviewMailbox {
    typealias Snapshot = [LiveObservationReviewAssignment]
    private let write: (Snapshot) async -> Bool
    private let report: (Bool) -> Void
    private var pending: Snapshot?
    private var work: Task<Void, Never>?
    private var cancelled = false
    private(set) var failed = false

    init(write: @escaping (Snapshot) async -> Bool, report: @escaping (Bool) -> Void = { _ in }) {
        self.write = write
        self.report = report
    }

    func enqueue(_ snapshot: Snapshot) {
        guard !cancelled else { return }
        pending = snapshot
        guard work == nil else { return }
        work = Task(name: "Review live speaker observations") { [self] in
            defer { work = nil }
            while !cancelled, let next = pending {
                pending = nil
                let saved = await write(next)
                guard !cancelled, !Task.isCancelled else { return }
                failed = !saved
                report(saved)
            }
        }
    }

    func drain() async { await work?.value }

    func cancel() {
        cancelled = true
        pending = nil
        work?.cancel()
    }
}
