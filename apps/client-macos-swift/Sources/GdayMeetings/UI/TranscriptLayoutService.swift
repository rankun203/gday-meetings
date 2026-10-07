import AppKit
import OSLog
import SwiftUI

enum TranscriptLayoutMetrics {
    static let logger = Logger(subsystem: CaptureLog.subsystem, category: "transcript-layout")
    static let signposter = OSSignposter(logger: logger)
}

/// Heights belong to a window, not a table. Entries retain no transcript text,
/// AppKit views, or text-layout objects. The byte budget is a bookkeeping estimate.
struct TranscriptMeasurementKey: Hashable, Sendable {
    let meetingID: UUID
    let rowID: UUID
    let textRevision: UInt64
    let effectiveWidth: CGFloat
    let typographyVersion: UInt64
    let layoutVersion: UInt64
}

struct TranscriptMeasurementInput: Sendable {
    let key: TranscriptMeasurementKey
    let text: String
    var estimatedBytes: Int { text.utf8.count + 128 }
}

/// Uses the same NSString metrics and system font as the native text field. Each
/// worker owns its inputs and font; no table, cell, or shared layout engine crosses threads.
enum TranscriptTextMeasurement {
    static func height(_ input: TranscriptMeasurementInput) -> CGFloat {
        let size = (input.text as NSString).boundingRect(
            with: NSSize(width: input.key.effectiveWidth - 4, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).size
        return max(20, ceil(size.height) + 2) + 8
    }
    static func normalizedTextWidth(_ width: CGFloat, showsSpeakers: Bool, scale: CGFloat) -> CGFloat {
        let scale = max(1, scale)
        return max(40, floor((width - (showsSpeakers ? 200 : 88)) * scale) / scale)
    }
}

@MainActor final class TranscriptLayoutService: ObservableObject {
    struct Statistics {
        var hits = 0
        var misses = 0
        var measurements = 0
        var batches = 0
        var cancelledBatches = 0
        var evictions = 0
        var peakPendingBytes = 0
        var peakPendingCount = 0
    }
    private struct Entry {
        var height: CGFloat
        var access: UInt64
        var previous: TranscriptMeasurementKey?
        var next: TranscriptMeasurementKey?
    }
    private var entries: [TranscriptMeasurementKey: Entry] = [:]
    private struct RowKey: Hashable {
        let meetingID: UUID
        let rowID: UUID
    }
    private var rowEntries: [RowKey: Set<TranscriptMeasurementKey>] = [:]
    private var clock: UInt64 = 0
    private var oldest: TranscriptMeasurementKey?
    private var newest: TranscriptMeasurementKey?
    private var meetingEntries: [UUID: Set<TranscriptMeasurementKey>] = [:]
    private var protectedKeys: Set<TranscriptMeasurementKey> = []
    private var owner: UUID?
    private var removedMeeting: UUID?
    private var retry: (() -> Void)?
    private var publication: ((Set<TranscriptMeasurementKey>) -> Void)?
    private var pending: [TranscriptMeasurementInput] = []
    private var inFlight: Set<TranscriptMeasurementKey> = []
    private var worker: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var inFlightBytes = 0
    private let budget: Int
    private let widthsPerRow: Int
    private let pendingByteBudget: Int
    private let pendingCountLimit: Int
    private let batchSize: Int
    private var memoryPressure: DispatchSourceMemoryPressure?
    // Dictionary/key/entry overhead varies by Swift release. Tune using Allocations.
    static let estimatedEntryBytes = 640
    private(set) var statistics = Statistics()
    var entryCount: Int { entries.count }
    var estimatedBytes: Int { entries.count * Self.estimatedEntryBytes }
    var pendingCount: Int { pending.count + inFlight.count }
    var pendingBytes: Int { inFlightBytes + pending.reduce(0) { $0 + $1.estimatedBytes } }

    init(
        budget: Int = 16 * 1024 * 1024, widthsPerRow: Int = 3,
        pendingByteBudget: Int = 1024 * 1024, pendingCountLimit: Int = 128, batchSize: Int = 16
    ) {
        self.budget = max(Self.estimatedEntryBytes, budget)
        self.widthsPerRow = max(1, widthsPerRow)
        self.pendingByteBudget = max(1, pendingByteBudget)
        self.pendingCountLimit = max(1, pendingCountLimit)
        self.batchSize = max(1, batchSize)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in self?.discardInactive() }
        pressure.resume()
        memoryPressure = pressure
    }
    deinit {
        worker?.cancel()
        memoryPressure?.cancel()
    }
    func height(for key: TranscriptMeasurementKey) -> CGFloat? {
        guard let entry = entries[key] else {
            statistics.misses += 1
            return nil
        }
        statistics.hits += 1
        touch(key)
        return entry.height
    }
    func isAvailable(to id: UUID) -> Bool { owner == nil || owner == id }
    func invalidate(meetingID: UUID, removing rowIDs: Set<UUID>) {
        for rowID in rowIDs {
            for key in Array(rowEntries[RowKey(meetingID: meetingID, rowID: rowID)] ?? []) { removeEntry(key) }
        }
        if inFlight.contains(where: { $0.meetingID == meetingID && rowIDs.contains($0.rowID) }) {
            cancelWork()
        }
        else {
            pending.removeAll { $0.key.meetingID == meetingID && rowIDs.contains($0.key.rowID) }
        }
    }
    func activate(
        _ id: UUID, retry: @escaping () -> Void = {}, publication: @escaping (Set<TranscriptMeasurementKey>) -> Void
    ) {
        self.retry = retry
        guard owner != id else {
            self.publication = publication
            return
        }
        cancelWork()
        removedMeeting = nil
        owner = id
        self.publication = publication
        protectedKeys = []
    }
    func deactivate(_ id: UUID) {
        guard owner == id else { return }
        TranscriptLayoutMetrics.logger.info(
            "Transcript cache: entries=\(self.entryCount) estimatedBytes=\(self.estimatedBytes) hits=\(self.statistics.hits) misses=\(self.statistics.misses) measurements=\(self.statistics.measurements) batches=\(self.statistics.batches) cancelled=\(self.statistics.cancelledBatches) peakPendingBytes=\(self.statistics.peakPendingBytes) peakPendingCount=\(self.statistics.peakPendingCount)"
        )
        cancelWork()
        owner = nil
        publication = nil
        retry = nil
        protectedKeys = []
        evict()
    }
    /// Replace priority rather than enqueueing a transcript for every page passed.
    /// The caller supplies visible rows first, then a small viewport margin.
    func request(_ inputs: [TranscriptMeasurementInput], owner id: UUID) {
        guard owner == id else { return }
        let wanted = Set(inputs.map(\.key))
        if !inFlight.isEmpty && inFlight.isDisjoint(with: wanted) { cancelWork() }
        protectedKeys = Set(inputs.prefix(min(pendingCountLimit, budget / Self.estimatedEntryBytes)).map(\.key))
        pending = []
        var seen = inFlight
        var bytes = inFlightBytes
        for input in inputs
        where input.key.meetingID != removedMeeting && entries[input.key] == nil && seen.insert(input.key).inserted {
            guard pending.count + inFlight.count < pendingCountLimit else { break }
            // A single unusually large row is allowed alone, so it cannot starve.
            if bytes + input.estimatedBytes > pendingByteBudget && (!pending.isEmpty || !inFlight.isEmpty) { break }
            pending.append(input)
            bytes += input.estimatedBytes
        }
        statistics.peakPendingBytes = max(statistics.peakPendingBytes, bytes)
        statistics.peakPendingCount = max(statistics.peakPendingCount, pendingCount)
        evict()
        startWorker()
    }
    func invalidate(meetingID: UUID, retaining rowIDs: Set<UUID>) {
        for key in Array(meetingEntries[meetingID] ?? []) where !rowIDs.contains(key.rowID) {
            removeEntry(key)
        }
        if inFlight.contains(where: { $0.meetingID == meetingID && !rowIDs.contains($0.rowID) }) {
            cancelWork()
        }
        else {
            pending.removeAll { $0.key.meetingID == meetingID && !rowIDs.contains($0.key.rowID) }
        }
    }
    func remove(meetingID: UUID) {
        removedMeeting = meetingID
        for key in Array(meetingEntries[meetingID] ?? []) { removeEntry(key) }
        protectedKeys = protectedKeys.filter { $0.meetingID != meetingID }
        cancelWork()
    }
    func discardInactive() {
        for key in Array(entries.keys) where !protectedKeys.contains(key) { removeEntry(key) }
        evict()
    }
    private func unlink(_ key: TranscriptMeasurementKey) {
        guard let entry = entries[key] else { return }
        if let previous = entry.previous {
            entries[previous]?.next = entry.next
        }
        else {
            oldest = entry.next
        }
        if let next = entry.next {
            entries[next]?.previous = entry.previous
        }
        else {
            newest = entry.previous
        }
    }
    private func touch(_ key: TranscriptMeasurementKey) {
        guard entries[key] != nil else { return }
        clock &+= 1
        entries[key]?.access = clock
        guard newest != key else { return }
        unlink(key)
        entries[key]?.previous = newest
        entries[key]?.next = nil
        if let newest {
            entries[newest]?.next = key
        }
        else {
            oldest = key
        }
        newest = key
    }
    private func insert(_ key: TranscriptMeasurementKey, height: CGFloat) {
        if entries[key] != nil {
            entries[key]?.height = height
            touch(key)
            return
        }
        clock &+= 1
        entries[key] = Entry(height: height, access: clock, previous: newest, next: nil)
        if let newest {
            entries[newest]?.next = key
        }
        else {
            oldest = key
        }
        newest = key
        rowEntries[RowKey(meetingID: key.meetingID, rowID: key.rowID), default: []].insert(key)
        meetingEntries[key.meetingID, default: []].insert(key)
    }
    private func removeEntry(_ key: TranscriptMeasurementKey) {
        unlink(key)
        entries.removeValue(forKey: key)
        let row = RowKey(meetingID: key.meetingID, rowID: key.rowID)
        rowEntries[row]?.remove(key)
        if rowEntries[row]?.isEmpty == true { rowEntries.removeValue(forKey: row) }
        meetingEntries[key.meetingID]?.remove(key)
        if meetingEntries[key.meetingID]?.isEmpty == true { meetingEntries.removeValue(forKey: key.meetingID) }
    }
    private func cancelWork() {
        revision &+= 1
        worker?.cancel()
        pending = []
    }
    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        let batch = Array(pending.prefix(batchSize))
        pending.removeFirst(batch.count)
        inFlight = Set(batch.map(\.key))
        inFlightBytes = batch.reduce(0) { $0 + $1.estimatedBytes }
        let revision = revision
        statistics.batches += 1
        worker = Task { [weak self] in
            let measurement = Task.detached(priority: .utility) {
                let signposter = TranscriptLayoutMetrics.signposter
                let state = signposter.beginInterval("Transcript measurement batch", id: signposter.makeSignpostID())
                defer { signposter.endInterval("Transcript measurement batch", state) }
                var result: [(TranscriptMeasurementKey, CGFloat)] = []
                for input in batch {
                    guard !Task.isCancelled else { break }
                    let height = autoreleasepool { TranscriptTextMeasurement.height(input) }
                    result.append((input.key, height))
                }
                return result
            }
            let values = await withTaskCancellationHandler {
                await measurement.value
            } onCancel: {
                measurement.cancel()
            }
            guard let self else { return }
            self.worker = nil
            self.inFlight = []
            self.inFlightBytes = 0
            guard revision == self.revision, !Task.isCancelled else {
                self.statistics.cancelledBatches += 1
                self.retry?()
                self.startWorker()
                return
            }
            var changed: Set<TranscriptMeasurementKey> = []
            for (key, height) in values {
                self.statistics.measurements += 1
                if self.entries[key]?.height != height { changed.insert(key) }
                self.insert(key, height: height)
                self.trimVariants(for: key)
            }
            self.evict()
            self.publication?(changed)
            self.startWorker()
        }
    }
    private func trimVariants(for key: TranscriptMeasurementKey) {
        let variants = (rowEntries[RowKey(meetingID: key.meetingID, rowID: key.rowID)] ?? [])
            .sorted { entries[$0]!.access < entries[$1]!.access }
        for obsolete in variants.prefix(max(0, variants.count - widthsPerRow)) {
            removeEntry(obsolete)
            statistics.evictions += 1
        }
    }
    private func evict() {
        let maximum = budget / Self.estimatedEntryBytes
        while entries.count > maximum, let first = oldest {
            var candidate = first
            // Protected rows are bounded by the entry budget; scan only those,
            // rather than sorting or walking the inactive library.
            var remaining = protectedKeys.count
            while protectedKeys.contains(candidate), remaining > 0, let next = entries[candidate]?.next {
                candidate = next
                remaining -= 1
            }
            removeEntry(candidate)
            statistics.evictions += 1
        }
    }
    /// Tests await actual worker completion; production never measures in a delegate.
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }
}

private struct TranscriptLayoutServiceKey: EnvironmentKey {
    static let defaultValue: TranscriptLayoutService? = nil
}
extension EnvironmentValues {
    var transcriptLayoutService: TranscriptLayoutService? {
        get { self[TranscriptLayoutServiceKey.self] }
        set { self[TranscriptLayoutServiceKey.self] = newValue }
    }
}
