import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptCSVTests {
    private func fixture() -> [LiveTranscriptJournalRecord] {
        let session = UUID()
        let generation = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.liveSources = [.microphone, .system]
        var speaker = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: generation, slot: 0,
            model: "synthetic", revision: "1")
        speaker.voiceEmbedding = .init(
            type: .init(
                modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: 3, normalization: "unitL2"),
            values: [0.123456789012345, -0.234567890123456, 0.964])
        var phrase = LiveTranscriptPhrase(
            session: session, source: .system, start: 0.125, end: 1.987654321,
            text: "Hello, \"world\".\n你好\r\nNext",
            words: [
                .init(text: "Hello,", start: 0.125, end: 0.4),
                .init(text: "\"world\".\n你好\r\nNext", start: 0.5, end: 1.987654321),
            ], locale: "en", recognizedFinal: false)
        var events: [LiveTranscriptJournalRecord] = [.begin(draft, labeling: true), .phrase(phrase, final: false)]
        events.append(
            .speaker(
                .init(
                    source: .system, generation: generation, sequence: 0, speakers: [speaker],
                    intervals: [.init(speakerID: speaker.id, start: 0, end: 2)], start: 0, end: 2)))
        phrase.recognizedFinal = true
        events.append(.phrase(phrase, final: true))
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: [speaker])
        draft.updateText("Edited, \"example\".\nSecond line.", for: phrase)
        events.append(.state(draft, labeling: true))
        speaker.personID = UUID()
        speaker.manuallyAssigned = true
        draft.speakerTimeline?.speakers = [speaker]
        events.append(.state(draft, labeling: false))
        draft.overrides = []
        draft.speakerLabelsComplete = true
        events.append(.state(draft, labeling: true))
        draft.overrides = nil
        draft.speakerLabelsComplete = nil
        speaker.personID = nil
        speaker.voiceEmbedding = nil
        draft.speakerTimeline?.speakers = [speaker]
        events.append(.state(draft, labeling: true))
        events.append(
            .speaker(
                .init(
                    source: .system, generation: generation, sequence: 1, speakers: [speaker],
                    intervals: [], start: 2, end: 3, final: true)))
        events.append(
            .gap(.init(source: .microphone, start: 3, end: 4, reason: "Example, gap\ncontinued"), speaker: false))
        events.append(.gap(.init(source: .system, start: 4, end: 5, reason: "Speaker gap"), speaker: true))
        events.append(.discardPartials)
        events.append(.finish)
        return events
    }

    private func encode(_ records: [LiveTranscriptJournalRecord]) throws -> Data {
        let codec = LiveTranscriptCSV()
        return try records.reduce(into: LiveTranscriptCSV.header) { $0.append(try codec.encode($1)) }
    }

    @Test func replayPreservesRevisionsUnicodeTimingEditsAndSpeakerChanges() throws {
        let records = fixture()
        let bytes = try encode(records)
        let decoded = try LiveTranscriptCSV().restore(bytes)
        #expect(decoded.committedBytes == bytes.count)
        #expect(decoded.records.count == records.count)
        #expect(LiveTranscriptJournalRecord.replay(decoded.records) == LiveTranscriptJournalRecord.replay(records))
        for count in 1...records.count {
            let prefix = Array(records.prefix(count))
            let restored = try LiveTranscriptCSV().restore(encode(prefix)).records
            #expect(LiveTranscriptJournalRecord.replay(restored) == LiveTranscriptJournalRecord.replay(prefix))
        }
    }

    @Test(arguments: ["First\r\nSecond", "First\rSecond", "First\nSecond", "", "🙂,\"你好\""])
    func quotesEveryCSVControlByte(text: String) throws {
        let draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let records: [LiveTranscriptJournalRecord] = [
            .begin(draft, labeling: false),
            .gap(.init(source: .system, start: 0, end: 1, reason: text), speaker: false),
        ]
        let decoded = try LiveTranscriptCSV().restore(encode(records)).records
        #expect(LiveTranscriptJournalRecord.replay(decoded) == LiveTranscriptJournalRecord.replay(records))
    }

    @Test func everyInterruptedByteRetainsOnlyWholeTransactions() throws {
        let records = Array(fixture().prefix(2))
        let codec = LiveTranscriptCSV()
        var bytes = LiveTranscriptCSV.header
        var boundaries = [bytes.count]
        for event in records {
            bytes.append(try codec.encode(event))
            boundaries.append(bytes.count)
        }
        for end in LiveTranscriptCSV.header.count...bytes.count {
            let prefix = Data(bytes.prefix(end))
            let decoded = try LiveTranscriptCSV().restore(prefix)
            #expect(decoded.committedBytes == boundaries.last(where: { $0 <= end }))
            #expect(decoded.records.count == boundaries.filter { $0 <= end }.count - 1)
        }
    }

    @Test func checksumUnknownVersionAndMalformedCompleteRowsFail() throws {
        var bytes = try encode(Array(fixture().prefix(2)))
        let textRange = try #require(bytes.range(of: Data("Hello".utf8)))
        bytes[textRange.lowerBound] = 74
        #expect(throws: Error.self) { try LiveTranscriptCSV().restore(bytes) }
        let wrongHeader = Data((LiveTranscriptCSV.columns + "h,0,,,,,,,version,999\n").utf8)
        #expect(throws: Error.self) { try LiveTranscriptCSV().restore(wrongHeader) }
        var malformed = try encode(Array(fixture().prefix(1)))
        malformed.append(Data("unknown,2,,,,,,,,\n".utf8))
        #expect(throws: Error.self) { try LiveTranscriptCSV().restore(malformed) }
    }

    @Test func resumedWriterRestoresReferencesAndDropsUncommittedTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("live-transcript-events.csv")
        let events = fixture()
        let writer = LiveTranscriptJournal<LiveTranscriptJournalRecord>.events(at: url)
        for event in events.prefix(5) { #expect(writer.append(event)) }
        try await writer.flush()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data("d,6,999,,,,,,uuid,00000000-0000-4000-8000-000000000001\nu,6,,,,,,,labeling,1\n".utf8))
        try handle.close()
        let resumed = LiveTranscriptJournal<LiveTranscriptJournalRecord>.events(at: url)
        for event in events.dropFirst(5) { #expect(resumed.append(event)) }
        try await resumed.flush()
        let decoded = try LiveTranscriptJournal<LiveTranscriptJournalRecord>.readEvents(from: url)
        #expect(decoded.count == events.count)
        #expect(LiveTranscriptJournalRecord.replay(decoded) == LiveTranscriptJournalRecord.replay(events))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func obsoleteEventFilesAreIgnoredAndLeftUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("live-transcript-events.jsonl")
        let bytes = Data("Unsupported old event file.\n".utf8)
        try bytes.write(to: old)
        let meetingID = UUID()
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: meetingID) == nil)
        let writer = LiveTranscriptJournal<LiveTranscriptJournalRecord>.events(
            at: directory.appendingPathComponent("live-transcript-events.csv"))
        writer.append(.begin(.init(meetingID: meetingID, locale: "en"), labeling: false))
        try await writer.flush()
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: meetingID)?.meetingID == meetingID)
        #expect(try Data(contentsOf: old) == bytes)
    }

    @Test func repeatedStatesAndSpeakerDefinitionsStaySmall() throws {
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let generation = UUID()
        let speakers = (0..<16).map {
            LiveSpeakerIdentity(
                id: UUID(), source: .system, generation: generation, slot: $0,
                model: String(repeating: "synthetic-model-", count: 30), revision: "1")
        }
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: speakers)
        let codec = LiveTranscriptCSV()
        _ = try codec.encode(.begin(draft, labeling: true))
        _ = try codec.encode(.state(draft, labeling: true))
        let repeated = try codec.encode(.state(draft, labeling: true))
        #expect(repeated.count < 180)
        let legacy = try JSONEncoder().encode(LiveTranscriptJournalRecord.state(draft, labeling: true))
        #expect(repeated.count * 20 < legacy.count)
        _ = try codec.encode(
            .speaker(
                .init(
                    source: .system, generation: generation, sequence: 0,
                    speakers: speakers, intervals: [], start: 0, end: 1)))
        let next = try codec.encode(
            .speaker(
                .init(
                    source: .system, generation: generation, sequence: 1,
                    speakers: speakers, intervals: [], start: 1, end: 2)))
        #expect(next.count < 400)
    }
}
