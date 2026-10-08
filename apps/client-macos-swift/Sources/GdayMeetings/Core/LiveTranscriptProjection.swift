import Foundation

/// Stable transcript rows, not recognition events. The atomic checkpoint commits
/// a byte prefix plus the replaceable recent rows and current manual corrections.
enum LiveTranscriptProjection {
    static let rowsName = TranscriptStorage.filename
    static let checkpointName = "transcript-checkpoint.json"

    struct Checkpoint: Codable {
        var version = 2
        var bytes: UInt64
        var rows: Int
        var draft: LiveTranscriptDraft
        var segments: [TranscriptSegment]
        var finished: Bool
    }

    static func checkpoint(at directory: URL) throws -> Checkpoint? {
        let url = directory.appendingPathComponent(checkpointName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        guard value.version == 2 else {
            throw MeetingError.message("This transcript checkpoint uses an unsupported format.")
        }
        return value
    }

    static func read(at directory: URL, meetingID: UUID) throws -> LiveTranscriptDraft? {
        try TranscriptStorage.coordinated(at: directory) {
            guard let checkpoint = try checkpoint(at: directory) else { return nil }
            guard checkpoint.draft.meetingID == meetingID else {
                throw MeetingError.message("The transcript checkpoint does not match its meeting.")
            }
            var draft = checkpoint.draft
            let segments = try TranscriptStorage.read(at: directory)
            draft.savedSegments = segments
            draft.effectivePhrases = segments.map { $0.livePhrase(meetingID: meetingID) }
            draft.phrases = draft.effectivePhrases ?? []
            // Current speaker metadata is sufficient to display saved rows.
            // Raw recognition and word attribution are not needed for viewing.
            draft.overrides = nil
            return draft
        }
    }
}

/// One writer appends completed display paragraphs and atomically checkpoints the
/// recent tail. Editing sealed text rewrites the small segment document at edit time.
actor LiveTranscriptProjectionStorage {
    private var head: LiveTranscriptFrozenBlock?
    private var carry: [LiveTranscriptPhrase] = []
    private var bytes: UInt64 = 0
    private var rowCount = 0
    private var committedSpeakerIDs = Set<UUID>()
    private var initialized = false
    private var lastOverrides: [LiveTranscriptOverride] = []

    private func additions(after previous: LiveTranscriptFrozenBlock?, through next: LiveTranscriptFrozenBlock?)
        -> [LiveTranscriptPhrase]
    {
        var blocks: [LiveTranscriptFrozenBlock] = []
        var cursor = next
        while let block = cursor, block !== previous {
            blocks.append(block)
            cursor = block.previous
        }
        return blocks.reversed().flatMap(\.rows)
    }

    private func paragraphs(_ rows: [LiveTranscriptPhrase], metadata: LiveTranscriptDraft) -> [LiveTranscriptPhrase] {
        var draft = metadata
        draft.savedSegments = nil
        draft.effectivePhrases = rows
        draft.overrides = (metadata.overrides ?? []).filter { change in rows.contains { $0.overlaps(change.anchor) } }
        return LiveTranscriptParagraphs.groups(
            finalized: draft.resolvedRows().finalized, partials: [], overrides: draft.overrides ?? []
        ).map(\.phrase)
    }

    func save(
        _ metadata: LiveTranscriptDraft, snapshot: LiveTranscriptEffectiveSnapshot, at directory: URL,
        finished: Bool = false
    ) throws {
        try TranscriptStorage.coordinated(at: directory) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(LiveTranscriptProjection.rowsName)
            let rewriting = initialized && lastOverrides != (metadata.overrides ?? [])
            let incoming = additions(after: rewriting ? nil : head, through: snapshot.head)
            var stable = paragraphs((rewriting ? [] : carry) + incoming, metadata: metadata)
            let nextCarry = stable.isEmpty ? [] : [stable.removeLast()]
            let recent = paragraphs(nextCarry + snapshot.tail, metadata: metadata)
            let committed = (stable + (finished ? recent : [])).map { TranscriptSegment(live: $0) }
            var nextSpeakerIDs = rewriting ? Set<UUID>() : committedSpeakerIDs
            nextSpeakerIDs.formUnion(committed.compactMap(\.speakerID))
            let checkpointSpeakerIDs = nextSpeakerIDs.union(recent.compactMap(\.speakerIdentity))
            let added = try TranscriptStorage.encoded(committed)
            var nextBytes = rewriting ? 0 : bytes
            var nextCount = rewriting ? 0 : rowCount
            var transaction = LibraryFileTransaction(root: directory)
            do {
                if rewriting {
                    try transaction.remember(url)
                    try transaction.remember(directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
                    try PrivateTranscriptFile.write(added, name: LiveTranscriptProjection.rowsName, at: directory)
                }
                else {
                    if !initialized && !FileManager.default.fileExists(atPath: url.path) {
                        try PrivateTranscriptFile.write(Data(), name: LiveTranscriptProjection.rowsName, at: directory)
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    // Discard an append whose checkpoint was never committed.
                    try handle.truncate(atOffset: bytes)
                    try handle.seek(toOffset: bytes)
                    try handle.write(contentsOf: added)
                    try handle.synchronize()
                }
                nextBytes += UInt64(added.count)
                nextCount += committed.count
                var draft = metadata
                draft.phrases = []
                draft.effectivePhrases = nil
                draft.savedSegments = nil
                draft.overrides = nil
                if let timeline = draft.speakerTimeline {
                    draft.speakerTimeline = LiveCheckpointSpeakerHistory.compact(
                        timeline, referenced: checkpointSpeakerIDs,
                        overrides: metadata.overrides ?? [], finished: finished)
                }
                if !finished { draft.complete = false }
                let checkpoint = LiveTranscriptProjection.Checkpoint(
                    bytes: nextBytes, rows: nextCount,
                    draft: draft, segments: finished ? [] : recent.map { TranscriptSegment(live: $0) },
                    finished: finished)
                try PrivateTranscriptFile.write(
                    try JSONEncoder().encode(checkpoint), name: LiveTranscriptProjection.checkpointName, at: directory)
                if rewriting { try transaction.commit() }
                head = snapshot.head
                carry = finished ? [] : nextCarry
                bytes = nextBytes
                rowCount = nextCount
                committedSpeakerIDs = nextSpeakerIDs
                initialized = true
                lastOverrides = metadata.overrides ?? []
            }
            catch {
                if rewriting { try transaction.restore() }
                throw error
            }
        }
    }
}

/// Coalesce rapid updates without retaining a queue of historical snapshots.
@MainActor final class LiveTranscriptProjectionWriter {
    private struct Pending {
        var draft: LiveTranscriptDraft
        var snapshot: LiveTranscriptEffectiveSnapshot
        var directory: URL
        var finished: Bool
        var report: @MainActor (String?) -> Void
    }
    private let storage = LiveTranscriptProjectionStorage()
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private(set) var issue: String?

    func submit(
        _ draft: LiveTranscriptDraft, snapshot: LiveTranscriptEffectiveSnapshot, at directory: URL,
        finished: Bool = false, report: @escaping @MainActor (String?) -> Void
    ) {
        pending = Pending(draft: draft, snapshot: snapshot, directory: directory, finished: finished, report: report)
        guard worker == nil else { return }
        worker = Task(name: "Save live transcript projection") {
            while pending != nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard let next = pending else { continue }
                pending = nil
                do {
                    try await storage.save(
                        next.draft, snapshot: next.snapshot, at: next.directory, finished: next.finished)
                    issue = nil
                    next.report(nil)
                }
                catch {
                    issue = "Couldn’t save transcript segments. Check available storage."
                    next.report(issue)
                }
            }
            worker = nil
        }
    }

    func flush() async {
        while let worker { await worker.value }
    }
}
