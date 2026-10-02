import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptJournalTests {
    struct Record: Codable, Sendable, Equatable {
        var sequence: Int
        var text: String
    }

    // A test-only codec isolates queue, permissions, and write-failure behavior.
    // Production journals accept only the CSV codec.
    private func fixtureFormat<T: Codable & Sendable>() -> LiveTranscriptJournal<T>.Format {
        let header = Data("queue-test-fixture\n".utf8)
        return .init(
            header: header,
            encode: { value in
                var bytes = try JSONEncoder().encode(value)
                bytes.append(10)
                return bytes
            },
            restore: { data in
                guard data.starts(with: header) else { throw LiveTranscriptJournal<T>.Failure.corrupt }
                var offset = header.count
                var records: [T] = []
                while offset < data.count, let end = data[offset...].firstIndex(of: 10) {
                    records.append(try JSONDecoder().decode(T.self, from: data[offset..<end]))
                    offset = end + 1
                }
                return (records, offset)
            })
    }

    private func readFixture<T: Codable & Sendable>(_ type: T.Type, from url: URL) throws -> [T] {
        let format: LiveTranscriptJournal<T>.Format = fixtureFormat()
        return try format.restore(Data(contentsOf: url)).records
    }

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("live-transcript.journal")
    }

    @Test func orderedAppendFlushAndPrivatePermissions() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LiveTranscriptJournal<Record>(url: url, format: fixtureFormat())
        let records = (0..<100).map { Record(sequence: $0, text: "Example line.\nNext line.") }
        for record in records { #expect(writer.append(record)) }
        try await writer.flush()
        #expect(try readFixture(Record.self, from: url) == records)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func interruptedTailIsIgnoredAndRemovedBeforeMoreAppends() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = Record(sequence: 0, text: "First phrase.")
        let second = Record(sequence: 1, text: "Second phrase.")
        let writer = LiveTranscriptJournal<Record>(url: url, format: fixtureFormat())
        #expect(writer.append(first))
        try await writer.flush()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":1,\"text\":\"unfinished".utf8))
        try handle.close()
        #expect(try readFixture(Record.self, from: url) == [first])
        let resumed = LiveTranscriptJournal<Record>(url: url, format: fixtureFormat())
        #expect(resumed.append(second))
        try await resumed.flush()
        #expect(try readFixture(Record.self, from: url) == [first, second])
    }

    @Test func malformedCommittedRecordFailsWithoutChangingFile() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LiveTranscriptJournal<Record>(url: url, format: fixtureFormat())
        #expect(writer.append(Record(sequence: 0, text: "First phrase.")))
        try await writer.flush()
        var damaged = try Data(contentsOf: url)
        damaged.append(contentsOf: "invalid record\n".utf8)
        try damaged.write(to: url)
        #expect(throws: Error.self) { try readFixture(Record.self, from: url) }
        let resumed = LiveTranscriptJournal<Record>(url: url, format: fixtureFormat())
        #expect(resumed.append(Record(sequence: 1, text: "Second phrase.")))
        await #expect(throws: Error.self) { try await resumed.flush() }
        #expect(!resumed.append(Record(sequence: 2, text: "Third phrase.")))
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func unsupportedHeaderIsRejected() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("unsupported-test-header\n".utf8).write(to: url)
        #expect(throws: Error.self) { try readFixture(Record.self, from: url) }
    }

    @Test func oversizedRecordFailsBeforeWritingAndRejectsLaterRecords() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LiveTranscriptJournal<Record>(url: url, maximumRecordBytes: 64, format: fixtureFormat())
        let first = Record(sequence: 0, text: "First phrase.")
        #expect(writer.append(first))
        try await writer.flush()
        #expect(writer.append(Record(sequence: 1, text: String(repeating: "x", count: 100))))
        await #expect(throws: Error.self) { try await writer.flush() }
        #expect(!writer.append(Record(sequence: 2, text: "Third phrase.")))
        #expect(try readFixture(Record.self, from: url) == [first])
    }

    final class Gate: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func waitForStart() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.started.wait()
                    continuation.resume()
                }
            }
        }
    }

    struct BlockingRecord: Codable, Sendable {
        let sequence: Int
        let gate: Gate?
        init(sequence: Int, gate: Gate? = nil) {
            self.sequence = sequence
            self.gate = gate
        }
        init(from decoder: Decoder) throws {
            sequence = try decoder.singleValueContainer().decode(Int.self)
            gate = nil
        }
        func encode(to encoder: Encoder) throws {
            if let gate {
                gate.started.signal()
                gate.release.wait()
            }
            var container = encoder.singleValueContainer()
            try container.encode(sequence)
        }
    }

    @Test func saturatedQueuePreservesAcceptedPrefixAndReportsFailure() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LiveTranscriptJournal<BlockingRecord>(url: url, limit: 2, format: fixtureFormat())
        let gate = Gate()
        #expect(writer.append(BlockingRecord(sequence: 0, gate: gate)))
        await gate.waitForStart()
        #expect(writer.append(BlockingRecord(sequence: 1)))
        #expect(!writer.append(BlockingRecord(sequence: 2)))
        gate.release.signal()
        await #expect(throws: Error.self) { try await writer.flush() }
        #expect(!writer.append(BlockingRecord(sequence: 3)))
        #expect(try readFixture(BlockingRecord.self, from: url).map(\.sequence) == [0, 1])
    }
}
