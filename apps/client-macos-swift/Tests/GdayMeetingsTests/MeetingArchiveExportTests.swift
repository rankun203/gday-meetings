import Foundation
import Testing

@testable import GdayMeetings

struct MeetingArchiveExportTests {
    @Test func filenamesArePortable() {
        #expect(MeetingArchiveExport.filename(for: "Design / review: Q4!") == "meeting-Design-review-Q4.zip")
        #expect(MeetingArchiveExport.filename(for: "Alpha_beta-123") == "meeting-Alpha_beta-123.zip")
        #expect(MeetingArchiveExport.filename(for: "会议 / 😀") == "meeting-untitled.zip")
        #expect(MeetingArchiveExport.filename(for: " .-_ ") == "meeting-untitled.zip")
        #expect(MeetingArchiveExport.filename(for: String(repeating: "a", count: 300)).count == 192)
    }

    @Test func viewerEscapesContentAndDoesNotExpandContentTokens() throws {
        let meeting = Meeting(
            title: "<script>alert(1)</script> {{SUMMARY}}",
            summary:
                "# Overview\n\n**Decision** and `code` <!-- gday:t=0:12 -->\n\n[Unsafe](javascript:alert)\n\n<script>bad()</script>",
            transcript: [
                .init(start: 12, end: 14, speaker: "A & B", text: "</script><img src=x onerror=bad()> {{TITLE}}")
            ],
            audioFiles: ["Track #1 & audio.opus"])
        let html = try MeetingArchiveExport.html(meeting)
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; {{SUMMARY}}"))
        #expect(html.contains("&lt;/script&gt;&lt;img src=x onerror=bad()&gt; {{TITLE}}"))
        #expect(html.contains("A &amp; B"))
        #expect(html.contains("Track%20%231%20%26%20audio%2Eopus"))
        #expect(html.contains("<strong>Decision</strong>"))
        #expect(html.contains("data-seek=\"12.0\""))
        #expect(!html.contains("href=\"javascript:"))
        #expect(!html.contains("<script>bad()"))
        #expect(!html.contains("<script src="))
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder)
    }

    @Test func summaryCitationsPlayWithoutTurningCodeIntoControls() {
        let html = MeetingArchiveExport.summaryHTML("Decision [01:23][02:05–02:10]. `Example [03:00]`")
        #expect(html.contains("data-seek=\"83.0\""))
        #expect(html.contains("data-seek=\"125.0\""))
        #expect(!html.contains("data-seek=\"180.0\""))
        #expect(html.contains("<code>Example [03:00]</code>"))
    }

    @Test func summaryRetainsLocalImageLinksAndAppMarkdownFormatting() {
        let html = MeetingArchiveExport.summaryHTML(
            "**结论：**检查示例。 [Diagram](assets/diagram.png) [Outside](assets/../../private.txt)")
        #expect(html.contains("<strong>结论：</strong>"))
        #expect(html.contains("href=\"assets/diagram.png\""))
        #expect(!html.contains("href=\"assets/../../private.txt\""))
    }
    private func unpack(_ zip: URL, to folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    @Test func archivePreservesFilesAndExcludesUnrelatedContent() throws {
        let (root, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = TranscriptSegment(start: 1, end: 4, speaker: "speaker_01", text: "Synthetic discussion")
        let transcript = try TranscriptStorage.encoded([row])
        try transcript.write(to: folder.appendingPathComponent(TranscriptStorage.filename))
        let summary = Data("# Summary\n\nA **synthetic** decision.".utf8)
        try summary.write(to: folder.appendingPathComponent("summary.md"))
        let audio = Data([0, 1, 2, 3])
        for name in ["microphone.opus", "system.opus"] { try audio.write(to: folder.appendingPathComponent(name)) }
        try Data("private evidence".utf8).write(to: folder.appendingPathComponent("speaker-evidence.jsonl"))
        try Data("private metadata".utf8).write(to: folder.appendingPathComponent("content.json"))
        var displayRow = row
        displayRow.speaker = "Alex"
        let meeting = Meeting(
            title: "Synthetic meeting", transcript: [displayRow], audioFiles: ["microphone.opus", "system.opus"])
        let destination = root.appendingPathComponent("meeting-synthetic.zip")
        try MeetingArchiveExport.write(meeting, directory: folder, to: destination)
        try MeetingArchiveExport.write(meeting, directory: folder, to: destination)
        let unpacked = root.appendingPathComponent("unpacked")
        try unpack(destination, to: unpacked)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: unpacked.path).sorted() == [
                "index.html", "microphone.opus", "summary.md", "system.opus", "transcripts.jsonl",
            ])
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("transcripts.jsonl")) == transcript)
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("summary.md")) == summary)
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("system.opus")) == audio)
        let html = try String(contentsOf: unpacked.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("Alex"))
        #expect(!html.contains("private evidence"))
        #expect(try Data(contentsOf: folder.appendingPathComponent(TranscriptStorage.filename)) == transcript)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".gday-export-") }
        )
    }

    @Test func unsafeInputsPreserveExistingDestination() throws {
        let (root, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("meeting.zip")
        let original = Data("previous archive".utf8)
        try original.write(to: output)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.opus"), withDestinationURL: output)
        for name in ["missing.opus", "../meeting.zip", "linked.opus", "index.html"] {
            #expect(throws: (any Error).self) {
                try MeetingArchiveExport.write(Meeting(audioFiles: [name]), directory: folder, to: output)
            }
            #expect(try Data(contentsOf: output) == original)
        }
        #expect(throws: (any Error).self) {
            try MeetingArchiveExport.write(
                Meeting(), directory: folder, to: folder.appendingPathComponent("export.zip"))
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".gday-export-") }
        )
    }

    @Test func emptyMeetingDoesNotInventSourceFiles() throws {
        let (root, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("meeting.zip")
        try MeetingArchiveExport.write(Meeting(), directory: folder, to: output)
        let unpacked = root.appendingPathComponent("unpacked")
        try unpack(output, to: unpacked)
        #expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["index.html"])
        let html = try String(contentsOf: unpacked.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("No summary available."))
        #expect(!html.contains("<audio id="))
    }
}
