import CryptoKit
import Foundation

/// CSV v2 preserves event order; a checksum commits all rows of one logical event.
/// Instances belong to a journal's serial utility queue, including their dictionaries.
final class LiveTranscriptCSV {
    typealias Record = LiveTranscriptJournalRecord
    typealias Journal = LiveTranscriptJournal<Record>
    static let columns = "event,tx,id,ref,source,start,end,final,key,value\n"
    static let header = Data((columns + "h,0,,,,,,,version,2\n").utf8)
    private var transaction = 0
    private var identifiers: [String: String] = [:]
    private var originals: [String: String] = [:]
    private var speakers: [String: String] = [:]
    private var stateFields: [String: String] = [:]
    private var overrides: [String: String] = [:]
    private var overrideOrder: [String] = []
    private var initial: LiveTranscriptDraft?

    var format: Journal.Format {
        .init(header: Self.header, encode: { try self.encode($0) }, restore: { try self.restore($0) })
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ value: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }

    private static func checksum(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func line(_ cells: [String]) -> Data {
        Data(
            (cells.map { value in
                if value.utf8.contains(where: { $0 == 44 || $0 == 34 || $0 == 10 || $0 == 13 }) {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: ",") + "\n").utf8)
    }

    private func reset() {
        transaction = 0
        identifiers = [:]
        originals = [:]
        speakers = [:]
        stateFields = [:]
        overrides = [:]
        overrideOrder = []
        initial = nil
    }

    func encode(_ event: Record) throws -> Data {
        transaction += 1
        var rows: [[String]] = []
        func row(
            _ event: String, id: String = "", ref: String = "", source: String = "",
            start: String = "", end: String = "", final: String = "", key: String = "", value: String = ""
        ) {
            rows.append([event, String(transaction), id, ref, source, start, end, final, key, value])
        }
        func reference(_ uuid: UUID) -> String {
            let original = uuid.uuidString
            if let id = identifiers[original] { return id }
            let id = String(identifiers.count + 1)
            identifiers[original] = id
            originals[id] = original
            row("d", id: id, key: "uuid", value: original)
            return id
        }
        func speaker(_ value: LiveSpeakerIdentity) throws {
            let id = reference(value.id)
            let encoded = try Self.json(value)
            if speakers[id] != encoded {
                row("u", id: id, key: "speaker", value: encoded)
                speakers[id] = encoded
            }
        }
        switch event {
        case .begin(let draft, let labeling):
            guard initial == nil else { throw Journal.Failure.corrupt }
            initial = draft
            row("b", final: labeling ? "1" : "0", value: try Self.json(draft))
        case .phrase(let phrase, let final):
            let id = reference(phrase.id)
            let session = reference(phrase.session)
            row(
                "p", id: id, ref: session, source: phrase.source == .microphone ? "m" : "s",
                start: String(phrase.start), end: String(phrase.end), final: final ? "1" : "0", value: phrase.text)
            for (index, word) in phrase.words.enumerated() {
                row("w", id: String(index), ref: id, start: String(word.start), end: String(word.end), value: word.text)
            }
            // Sparse optional phrase attributes retain the Codable schema without
            // duplicating text, timing, identity, or word arrays in a JSON cell.
            var attributes = try JSONSerialization.jsonObject(with: Data(Self.json(phrase).utf8)) as! [String: Any]
            for key in ["id", "session", "source", "start", "end", "text", "words"] {
                attributes.removeValue(forKey: key)
            }
            if !attributes.isEmpty {
                let bytes = try JSONSerialization.data(
                    withJSONObject: attributes, options: [.sortedKeys, .withoutEscapingSlashes])
                row("a", ref: id, value: String(decoding: bytes, as: UTF8.self))
            }
        case .speaker(let event):
            let generation = reference(event.generation)
            for value in event.speakers { try speaker(value) }
            let members = event.speakers.map { reference($0.id) }
            row(
                "s", id: String(event.sequence), ref: generation, source: event.source == .microphone ? "m" : "s",
                start: String(event.start), end: String(event.end), final: event.final ? "1" : "0",
                value: try Self.json(members))
            for interval in event.intervals {
                row("i", ref: reference(interval.speakerID), start: String(interval.start), end: String(interval.end))
            }
        case .state(let draft, let labeling):
            row("u", key: "labeling", value: labeling ? "1" : "0")
            let fields = [
                "locale": try Self.json(draft.locale), "complete": try Self.json(draft.complete),
                "speakerLabelsComplete": try Self.json(draft.speakerLabelsComplete),
                "overridesPresent": try Self.json(draft.overrides != nil),
            ]
            for key in fields.keys.sorted() where stateFields[key] != fields[key] {
                row("u", key: key, value: fields[key]!)
                stateFields[key] = fields[key]
            }
            for value in draft.speakerTimeline?.speakers ?? [] { try speaker(value) }
            var updated: [String: String] = [:]
            var order: [String] = []
            for value in draft.overrides ?? [] {
                let id = reference(value.id)
                let encoded = try Self.json(value)
                updated[id] = encoded
                order.append(id)
                if overrides[id] != encoded { row("u", id: id, key: "override", value: encoded) }
            }
            for id in overrides.keys.sorted() where updated[id] == nil {
                row("u", id: id, key: "override", value: "null")
            }
            if order != overrideOrder { row("u", key: "order", value: try Self.json(order)) }
            overrides = updated
            overrideOrder = order
        case .gap(let gap, let speaker):
            row(
                "g", source: gap.source == .microphone ? "m" : "s", start: String(gap.start), end: String(gap.end),
                final: speaker ? "1" : "0", value: gap.reason)
        case .finish: row("f")
        case .discardPartials: row("x")
        }
        var bytes = rows.reduce(into: Data()) { $0.append(Self.line($1)) }
        bytes.append(
            Self.line(["c", String(transaction), "", "", "", "", "", "", String(rows.count), Self.checksum(bytes)]))
        return bytes
    }

    /// Parses UTF-8 CSV records, including quoted newlines. An incomplete final
    /// transaction is ignored; malformed complete records and bad commits fail.
    func restore(_ data: Data) throws -> (records: [Record], committedBytes: Int) {
        reset()
        guard data.starts(with: Self.header) else { throw Journal.Failure.corrupt }
        var result: [Record] = []
        var committed = Self.header.count
        var transactionStart = committed
        var cursor = committed
        var rows: [[String]] = []
        while let parsed = try Self.nextRow(data, cursor: &cursor) {
            guard parsed.count == 10, parsed[1] == String(transaction + 1) else { throw Journal.Failure.corrupt }
            if parsed[0] == "c" {
                guard !rows.isEmpty, parsed[8] == String(rows.count),
                    parsed[9] == Self.checksum(data.subdata(in: transactionStart..<parsedStart(data, end: cursor)))
                else { throw Journal.Failure.corrupt }
                let record = try decodeRows(rows)
                result.append(record)
                transaction += 1
                committed = cursor
                transactionStart = cursor
                rows = []
            }
            else {
                guard ["d", "b", "p", "w", "a", "s", "i", "u", "g", "f", "x"].contains(parsed[0]) else {
                    throw Journal.Failure.corrupt
                }
                rows.append(parsed)
            }
        }
        return (result, committed)
    }

    // Commit rows contain no quoted cells or embedded newlines.
    private func parsedStart(_ data: Data, end: Int) -> Int {
        data[..<(end - 1)].lastIndex(of: 10).map { $0 + 1 } ?? 0
    }

    private static func nextRow(_ data: Data, cursor: inout Int) throws -> [String]? {
        guard cursor < data.count else { return nil }
        var cells: [String] = []
        var cell = Data()
        var quoted = false
        var closed = false
        var started = false
        while cursor < data.count {
            let byte = data[cursor]
            cursor += 1
            if quoted {
                if byte == 34 {
                    if cursor < data.count && data[cursor] == 34 {
                        cell.append(34)
                        cursor += 1
                    }
                    else {
                        quoted = false
                        closed = true
                    }
                }
                else {
                    cell.append(byte)
                }
            }
            else if byte == 44 || byte == 10 {
                guard let text = String(data: cell, encoding: .utf8) else { throw Journal.Failure.corrupt }
                cells.append(text)
                cell = Data()
                closed = false
                started = false
                if byte == 10 { return cells }
            }
            else if byte == 34 && !started && !closed {
                quoted = true
                started = true
            }
            else {
                guard !closed, byte != 34, byte != 13 else { throw Journal.Failure.corrupt }
                cell.append(byte)
                started = true
            }
        }
        return nil
    }

    private func decodeRows(_ rows: [[String]]) throws -> Record {
        var main: [String]?
        var words: [LiveTranscriptWord] = []
        var attributes: [String: Any] = [:]
        var intervals: [LiveSpeakerInterval] = []
        func uuid(_ id: String) throws -> UUID {
            guard let value = originals[id], let uuid = UUID(uuidString: value) else { throw Journal.Failure.corrupt }
            return uuid
        }
        func time(_ value: String) throws -> Double {
            guard let value = Double(value), value.isFinite, value >= 0 else { throw Journal.Failure.corrupt }
            return value
        }
        func flag(_ value: String) throws -> Bool {
            guard value == "0" || value == "1" else { throw Journal.Failure.corrupt }
            return value == "1"
        }
        func source(_ value: String) throws -> LiveAudioSource {
            guard value == "m" || value == "s" else { throw Journal.Failure.corrupt }
            return value == "m" ? .microphone : .system
        }
        for row in rows {
            switch row[0] {
            case "d":
                guard row[8] == "uuid", row[2] == String(identifiers.count + 1),
                    let value = UUID(uuidString: row[9]), identifiers[value.uuidString] == nil
                else { throw Journal.Failure.corrupt }
                originals[row[2]] = value.uuidString
                identifiers[value.uuidString] = row[2]
            case "u" where row[8] == "speaker":
                let speaker: LiveSpeakerIdentity = try Self.decode(row[9])
                guard speaker.id == (try uuid(row[2])) else { throw Journal.Failure.corrupt }
                speakers[row[2]] = row[9]
            case "u" where row[8] == "override":
                if row[9] == "null" {
                    overrides.removeValue(forKey: row[2])
                }
                else {
                    let value: LiveTranscriptOverride = try Self.decode(row[9])
                    guard value.id == (try uuid(row[2])) else { throw Journal.Failure.corrupt }
                    overrides[row[2]] = row[9]
                }
            case "u" where row[8] == "order": overrideOrder = try Self.decode(row[9])
            case "u" where row[8] != "labeling":
                guard ["locale", "complete", "speakerLabelsComplete", "overridesPresent"].contains(row[8]) else {
                    throw Journal.Failure.corrupt
                }
                stateFields[row[8]] = row[9]
            case "w":
                guard main?[0] == "p", main?[2] == row[3], row[2] == String(words.count) else {
                    throw Journal.Failure.corrupt
                }
                words.append(.init(text: row[9], start: try time(row[5]), end: try time(row[6])))
            case "a":
                guard main?[0] == "p", main?[2] == row[3], attributes.isEmpty,
                    let value = try JSONSerialization.jsonObject(with: Data(row[9].utf8)) as? [String: Any]
                else { throw Journal.Failure.corrupt }
                attributes = value
            case "i":
                guard main?[0] == "s" else { throw Journal.Failure.corrupt }
                intervals.append(.init(speakerID: try uuid(row[3]), start: try time(row[5]), end: try time(row[6])))
            default:
                guard main == nil, ["b", "p", "s", "u", "g", "f", "x"].contains(row[0]) else {
                    throw Journal.Failure.corrupt
                }
                main = row
            }
        }
        guard let row = main else { throw Journal.Failure.corrupt }
        switch row[0] {
        case "b":
            guard initial == nil else { throw Journal.Failure.corrupt }
            let draft: LiveTranscriptDraft = try Self.decode(row[9])
            initial = draft
            return .begin(draft, labeling: try flag(row[7]))
        case "p":
            attributes["id"] = try uuid(row[2]).uuidString
            attributes["session"] = try uuid(row[3]).uuidString
            attributes["source"] = try source(row[4]).rawValue
            attributes["start"] = try time(row[5])
            attributes["end"] = try time(row[6])
            attributes["text"] = row[9]
            attributes["words"] = try JSONSerialization.jsonObject(with: Data(Self.json(words).utf8))
            let phrase = try JSONDecoder().decode(
                LiveTranscriptPhrase.self, from: JSONSerialization.data(withJSONObject: attributes))
            return .phrase(phrase, final: try flag(row[7]))
        case "s":
            let members: [String] = try Self.decode(row[9])
            let values: [LiveSpeakerIdentity] = try members.map {
                guard let encoded = speakers[$0] else { throw Journal.Failure.corrupt }
                return try Self.decode(encoded)
            }
            guard let sequence = Int(row[2]), sequence >= 0 else { throw Journal.Failure.corrupt }
            return .speaker(
                .init(
                    source: try source(row[4]), generation: try uuid(row[3]), sequence: sequence,
                    speakers: values, intervals: intervals, start: try time(row[5]), end: try time(row[6]),
                    final: try flag(row[7])))
        case "u":
            guard var draft = initial, row[8] == "labeling" else { throw Journal.Failure.corrupt }
            if let value = stateFields["locale"] { draft.locale = try Self.decode(value) }
            if let value = stateFields["complete"] { draft.complete = try Self.decode(value) }
            if let value = stateFields["speakerLabelsComplete"] { draft.speakerLabelsComplete = try Self.decode(value) }
            let present: Bool = try Self.decode(stateFields["overridesPresent"] ?? "false")
            guard Set(overrideOrder).count == overrideOrder.count, Set(overrideOrder) == Set(overrides.keys) else {
                throw Journal.Failure.corrupt
            }
            draft.overrides = present ? try overrideOrder.map { try Self.decode(overrides[$0]!) } : nil
            if !speakers.isEmpty {
                draft.speakerTimeline = LiveSpeakerTimeline()
                draft.speakerTimeline?.speakers = try speakers.keys.sorted().map { try Self.decode(speakers[$0]!) }
            }
            return .state(draft, labeling: try flag(row[9]))
        case "g":
            return .gap(
                .init(source: try source(row[4]), start: try time(row[5]), end: try time(row[6]), reason: row[9]),
                speaker: try flag(row[7]))
        case "f": return .finish
        case "x": return .discardPartials
        default: throw Journal.Failure.corrupt
        }
    }
}

extension LiveTranscriptJournal where Record == LiveTranscriptJournalRecord {
    static func events(at url: URL) -> LiveTranscriptJournal<Record> {
        .init(url: url, format: LiveTranscriptCSV().format)
    }

    static func readEvents(from url: URL) throws -> [Record] {
        try LiveTranscriptCSV().restore(Data(contentsOf: url)).records
    }
}
