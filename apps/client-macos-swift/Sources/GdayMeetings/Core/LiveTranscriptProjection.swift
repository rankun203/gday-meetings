import Foundation

/// Stable transcript rows, not recognition events. The atomic checkpoint commits
/// a byte prefix plus the replaceable recent rows and current manual corrections.
enum LiveTranscriptProjection {
    static let rowsName = "live-transcript-segments.jsonl"
    static let rawRowsName = "live-transcript-speaker-evidence.jsonl"
    static let checkpointName = "live-transcript-segments-checkpoint.json"

    struct Checkpoint: Codable {
        var version = 1
        var bytes: UInt64
        var rows: Int
        var rawBytes: UInt64
        var rawRows: Int
        var draft: LiveTranscriptDraft
        var finished: Bool
    }

    static func read(at directory: URL, meetingID: UUID) throws -> LiveTranscriptDraft? {
        let checkpointURL = directory.appendingPathComponent(checkpointName)
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        guard checkpoint.version == 1, checkpoint.draft.meetingID == meetingID else {
            throw LiveTranscriptJournal<LiveTranscriptJournalRecord>.Failure.corrupt
        }
        let rows = try readRows(
            directory.appendingPathComponent(rowsName), bytes: checkpoint.bytes, count: checkpoint.rows)
        let raw = try readRows(
            directory.appendingPathComponent(rawRowsName), bytes: checkpoint.rawBytes, count: checkpoint.rawRows)
        var draft = checkpoint.draft
        draft.effectivePhrases = rows + draft.phrases
        draft.rawSpeakerPhrases = raw + (draft.rawSpeakerPhrases ?? [])
        draft.phrases = draft.rawSpeakerPhrases ?? []
        return draft
    }

    private static func readRows(_ url: URL, bytes: UInt64, count: Int) throws -> [LiveTranscriptPhrase] {
        guard count >= 0 else { throw LiveTranscriptJournal<LiveTranscriptJournalRecord>.Failure.corrupt }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = bytes
        var pending = Data()
        var rows: [LiveTranscriptPhrase] = []
        while remaining > 0 {
            let bytes = try handle.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !bytes.isEmpty else { throw LiveTranscriptJournal<LiveTranscriptJournalRecord>.Failure.corrupt }
            remaining -= UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                rows.append(try JSONDecoder().decode(LiveTranscriptPhrase.self, from: pending[..<newline]))
                pending.removeSubrange(...newline)
            }
        }
        guard pending.isEmpty, rows.count == count else {
            throw LiveTranscriptJournal<LiveTranscriptJournalRecord>.Failure.corrupt
        }
        return rows
    }
}

/// Only this actor touches append handles. A checkpoint is published after its
/// rows are synchronized; extra bytes from an interrupted write are ignored.
actor LiveTranscriptProjectionStorage {
    private struct Channel {
        var head: LiveTranscriptFrozenBlock?
        var bytes: UInt64 = 0
        var rows = 0
        var handle: FileHandle?

        mutating func append(_ newHead: LiveTranscriptFrozenBlock?, to url: URL) throws -> (UInt64, Int) {
            if handle == nil {
                guard
                    FileManager.default.createFile(
                        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else {
                    throw LiveTranscriptJournal<LiveTranscriptJournalRecord>.Failure.create
                }
                handle = try FileHandle(forWritingTo: url)
            }
            let handle = handle!
            // On retry, discard bytes not referenced by the last published checkpoint.
            try handle.truncate(atOffset: bytes)
            try handle.seek(toOffset: bytes)
            var blocks: [LiveTranscriptFrozenBlock] = []
            var cursor = newHead
            while let block = cursor, block !== head {
                blocks.append(block)
                cursor = block.previous
            }
            var nextBytes = bytes
            var nextRows = rows
            let encoder = JSONEncoder()
            for block in blocks.reversed() {
                for row in block.rows {
                    var line = try encoder.encode(row)
                    line.append(10)
                    try handle.write(contentsOf: line)
                    nextBytes += UInt64(line.count)
                    nextRows += 1
                }
            }
            try handle.synchronize()
            return (nextBytes, nextRows)
        }
    }
    private var effective = Channel()
    private var raw = Channel()

    func save(
        _ metadata: LiveTranscriptDraft, snapshot: LiveTranscriptEffectiveSnapshot, at directory: URL,
        finished: Bool = false
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (bytes, rows) = try effective.append(
            snapshot.head, to: directory.appendingPathComponent(LiveTranscriptProjection.rowsName))
        let (rawBytes, rawRows) = try raw.append(
            snapshot.rawHead, to: directory.appendingPathComponent(LiveTranscriptProjection.rawRowsName))
        var draft = metadata
        draft.phrases = snapshot.tail
        draft.effectivePhrases = nil
        draft.rawSpeakerPhrases = snapshot.rawTail
        draft.speakerTimeline?.intervals = []
        draft.committedJournalDigest = nil
        if !finished { draft.complete = false }
        let checkpoint = LiveTranscriptProjection.Checkpoint(
            bytes: bytes, rows: rows, rawBytes: rawBytes, rawRows: rawRows, draft: draft, finished: finished)
        try PrivateTranscriptFile.write(
            try JSONEncoder().encode(checkpoint), name: LiveTranscriptProjection.checkpointName, at: directory)
        effective.head = snapshot.head
        effective.bytes = bytes
        effective.rows = rows
        raw.head = snapshot.rawHead
        raw.bytes = rawBytes
        raw.rows = rawRows
    }

    deinit {
        try? effective.handle?.close()
        try? raw.handle?.close()
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
        worker = Task {
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
