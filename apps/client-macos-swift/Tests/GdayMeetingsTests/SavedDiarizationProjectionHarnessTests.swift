import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in projection checks over copied artifacts. Never opens a library or starts audio inference.
struct SavedDiarizationProjectionHarnessTests {
    private struct Metrics: Encodable {
        var sourceRows: Int
        var projectedRows: Int
        var attributedRows: Int
        var unresolvedRows: Int
        var uncertainRows: Int
        var inputTimedSpans: Int
        var outputTimedSpans: Int
        var attributedTimedSpans: Int
        var sourceSHA256: String
        var acousticSHA256: String
        var exactSourceTextAndAnchorsPreserved: Bool
        var timedSpansPreserved: Bool
        var projectionSeconds: Double
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_SAVED_PROJECTION"] == "1"))
    func projectCopiedArtifactsWithoutInference() throws {
        let environment = ProcessInfo.processInfo.environment
        func input(_ key: String) throws -> URL {
            URL(fileURLWithPath: try #require(environment[key])).standardizedFileURL.resolvingSymlinksInPath()
        }
        let sourceURL = try input("GDAY_SAVED_PROJECTION_SOURCE")
        let acousticURL = try input("GDAY_SAVED_PROJECTION_ACOUSTIC")
        let directory = try input("GDAY_SAVED_PROJECTION_OUTPUT")
        try #require(
            directory.path.hasPrefix("/private/tmp/") || directory.pathComponents.contains(".local"),
            "Write experiment outputs only in temporary or ignored .local storage.")
        let destination = directory.appendingPathComponent("projected.jsonl")
        let metricsURL = directory.appendingPathComponent("metrics.json")
        try #require(
            ![sourceURL, acousticURL].contains(destination) && ![sourceURL, acousticURL].contains(metricsURL))
        let sourceData = try Data(contentsOf: sourceURL)
        let acousticData = try Data(contentsOf: acousticURL)
        let decoder = JSONDecoder()
        let source = try decoder.decode(TranscriptionAnalysisArtifact.self, from: sourceData)
        let acoustic = try decoder.decode(LocalDiarizationResult.self, from: acousticData)
        let rows = source.segments
        try #require(source.version == 1 && !rows.isEmpty)
        try #require(Set(rows.map(\.id)).count == rows.count)
        try #require(rows.allSatisfy { $0.sourceSpans == nil }, "Use the original provider source artifact.")
        let tracks = Set(acoustic.trackSources.keys)
        try #require(!tracks.isEmpty && acoustic.ranges.allSatisfy { tracks.contains($0.track) })
        try #require(rows.allSatisfy { $0.analysisTrackID.map(tracks.contains) == true })
        var meeting = Meeting()
        meeting.transcript = rows
        let started = ProcessInfo.processInfo.systemUptime
        let projected = LocalDiarizationAssignment.applying(acoustic, to: meeting, fileCount: tracks.count).transcript
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try verifyAnchors(source: rows, projected: projected)
        let originalSpans = try timedSpanSignatures(rows)
        let projectedSpans = try timedSpanSignatures(projected)
        try #require(originalSpans == projectedSpans, "Projection must preserve every original timed span.")
        let attributed = projected.filter { $0.speakerID != nil && $0.sourcePlaceholder != true }
        let metrics = Metrics(
            sourceRows: rows.count, projectedRows: projected.count, attributedRows: attributed.count,
            unresolvedRows: projected.count - attributed.count,
            uncertainRows: projected.filter { $0.associationUncertain == true }.count,
            inputTimedSpans: originalSpans.count, outputTimedSpans: projectedSpans.count,
            attributedTimedSpans: attributed.reduce(0) { $0 + ($1.timing?.spans.count ?? 0) },
            sourceSHA256: hash(sourceData), acousticSHA256: hash(acousticData),
            exactSourceTextAndAnchorsPreserved: true, timedSpansPreserved: true, projectionSeconds: elapsed)
        let sourceAfter = try Data(contentsOf: sourceURL)
        let acousticAfter = try Data(contentsOf: acousticURL)
        try #require(sourceAfter == sourceData && acousticAfter == acousticData)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try TranscriptStorage.encoded(projected).write(to: destination, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: metricsURL, options: .atomic)
        for url in [destination, metricsURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func verifyAnchors(source: [TranscriptSegment], projected: [TranscriptSegment]) throws {
        let originals = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var collected: [UUID: [TranscriptSourceSpan]] = [:]
        for row in projected {
            let anchors =
                row.sourceSpans ?? [
                    TranscriptSourceSpan(
                        rowID: row.id, range: .init(location: 0, length: row.text.utf16.count), text: row.text)
                ]
            try #require(anchors.map { ($0.separatorBefore ?? "") + $0.text }.joined() == row.text)
            for anchor in anchors {
                let original = try #require(originals[anchor.rowID])
                let range = NSRange(location: anchor.range.location, length: anchor.range.length)
                try #require(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= original.text.utf16.count)
                try #require((original.text as NSString).substring(with: range) == anchor.text)
                collected[anchor.rowID, default: []].append(anchor)
            }
        }
        try #require(Set(collected.keys) == Set(originals.keys))
        for original in source {
            let anchors = collected[original.id, default: []].sorted { $0.range.location < $1.range.location }
            var cursor = 0
            for anchor in anchors {
                try #require(anchor.range.location == cursor, "Source anchors must not omit or duplicate text.")
                cursor += anchor.range.length
            }
            try #require(cursor == original.text.utf16.count && anchors.map(\.text).joined() == original.text)
        }
    }

    private func timedSpanSignatures(_ rows: [TranscriptSegment]) throws -> [String] {
        var signatures: [String] = []
        for row in rows {
            guard let timing = row.timing else { continue }
            try #require(timing.isValid && timing.text == row.text)
            for span in timing.spans {
                let text = (row.text as NSString).substring(
                    with: NSRange(location: span.range.location, length: span.range.length))
                signatures.append(
                    "\(span.start.bitPattern):\(span.end.bitPattern):\(span.granularity.rawValue):\(text)")
            }
        }
        return signatures.sorted()
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
