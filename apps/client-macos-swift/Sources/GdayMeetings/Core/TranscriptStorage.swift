import Foundation

/// The editable transcript and the streaming recording share one segment file.
enum TranscriptStorage {
    static let filename = "transcript.jsonl"
    private static let lock = NSRecursiveLock()

    static func coordinated<T>(at directory: URL, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try LibraryFileTransaction.recover(root: directory)
        return try operation()
    }

    static func read(at directory: URL) throws -> [TranscriptSegment] {
        try coordinated(at: directory) {
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                guard
                    !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(LiveTranscriptProjection.checkpointName).path)
                else {
                    throw MeetingError.message("The saved transcript is missing. Its checkpoint was kept.")
                }
                let legacy = [
                    "transcript.json", "live-transcript.json", "live-transcript-segments-checkpoint.json",
                    "live-transcript-segments.jsonl", "live-transcript-events.csv",
                ]
                guard
                    !legacy.contains(where: {
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                    })
                else {
                    throw MeetingError.message(
                        "This transcript needs migration to transcript.jsonl before it can be opened.")
                }
                return []
            }
            if let checkpoint = try LiveTranscriptProjection.transcriptCommit(at: directory), !checkpoint.finished {
                return try readRows(url, bytes: checkpoint.bytes, count: checkpoint.rows) + checkpoint.segments
            }
            return try readRows(url)
        }
    }

    static func readRows(_ url: URL, bytes: UInt64? = nil, count: Int? = nil) throws -> [TranscriptSegment] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = bytes
        var pending = Data()
        var rows: [TranscriptSegment] = []
        let decoder = JSONDecoder()
        while remaining == nil || remaining! > 0 {
            let data = try handle.read(upToCount: Int(min(remaining ?? 65536, 65536))) ?? Data()
            if data.isEmpty { break }
            if remaining != nil { remaining! -= UInt64(data.count) }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let row = try decoder.decode(TranscriptSegment.self, from: pending[..<newline])
                guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end >= row.start else {
                    throw MeetingError.message("The transcript contains an invalid time range.")
                }
                rows.append(row)
                pending.removeSubrange(...newline)
            }
        }
        if bytes == nil && !pending.isEmpty {
            let row = try decoder.decode(TranscriptSegment.self, from: pending)
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end >= row.start else {
                throw MeetingError.message("The transcript contains an invalid time range.")
            }
            rows.append(row)
            pending = Data()
        }
        guard pending.isEmpty, remaining == nil || remaining == 0, count == nil || rows.count == count else {
            throw MeetingError.message("The transcript contains an incomplete segment.")
        }
        return rows
    }

    static func encoded(_ rows: [TranscriptSegment]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(10)
        }
        return data
    }

    static func write(_ rows: [TranscriptSegment], at directory: URL) throws {
        try coordinated(at: directory) {
            var transaction = LibraryFileTransaction(root: directory)
            do {
                try transaction.remember(directory.appendingPathComponent(filename))
                try transaction.remember(directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
                try PrivateTranscriptFile.write(try encoded(rows), name: filename, at: directory)
                // Replacements and edits own the complete document. A recording's
                // old checkpoint must never resurrect deleted or replaced rows.
                let checkpoint = directory.appendingPathComponent(LiveTranscriptProjection.checkpointName)
                if FileManager.default.fileExists(atPath: checkpoint.path) {
                    try FileManager.default.removeItem(at: checkpoint)
                }
                try transaction.commit()
            }
            catch {
                try transaction.restore()
                throw error
            }
        }
    }
}

extension TranscriptSegment {
    init(live phrase: LiveTranscriptPhrase) {
        self.init(
            id: phrase.id, start: phrase.start, end: phrase.end, speaker: phrase.speakerLabel,
            text: phrase.text, speakerID: phrase.speakerIdentity ?? phrase.id,
            source: phrase.source, session: phrase.session,
            sourcePlaceholder: !phrase.hasSpeakerIdentity, personID: phrase.personID)
    }

    func livePhrase(meetingID: UUID) -> LiveTranscriptPhrase {
        LiveTranscriptPhrase(
            id: id, session: session ?? meetingID, source: source ?? .system,
            start: start, end: end, text: text, personID: personID,
            speakerIdentity: sourcePlaceholder == true ? nil : speakerID,
            diarizationLabel: speaker)
    }
}
