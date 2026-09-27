import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct NotesImageExportTests {
    private let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5V8AAAAASUVORK5CYII=")!
    private func fixture() throws -> (URL, Meeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("assets/original.png"))
        try png.write(to: root.appendingPathComponent("assets/display.png"))
        let notes =
            "<a href=\"assets/original.png\"><img src=\"assets/display.png\" width=\"120\" alt=\"Board\"></a> <!-- gday:t=0:12 -->"
        return (root, Meeting(title: "Board meeting", notes: notes))
    }

    @Test func markdownAndTextBundleIncludeOriginalAndDisplayFiles() throws {
        let (root, meeting) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("meeting.md")
        try MeetingExport.write(meeting, directory: root, to: markdown)
        let text = try String(contentsOf: markdown, encoding: .utf8)
        #expect(text.contains("meeting-assets/original.png"))
        #expect(text.contains("meeting-assets/display.png"))
        #expect(!text.contains("gday:t="))
        #expect(try Data(contentsOf: root.appendingPathComponent("meeting-assets/original.png")) == png)
        let bundle = root.appendingPathComponent("meeting.textbundle")
        try MeetingExport.write(meeting, directory: root, to: bundle)
        #expect(try Data(contentsOf: bundle.appendingPathComponent("assets/display.png")) == png)
        #expect(
            try String(contentsOf: bundle.appendingPathComponent("text.markdown"), encoding: .utf8).contains(
                "assets/original.png"))
        var info = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("info.json")))
                as? [String: Any])
        #expect(info["version"] as? Int == 2)
        info["other.editor"] = ["version": 1]
        try JSONSerialization.data(withJSONObject: info).write(to: bundle.appendingPathComponent("info.json"))
        try MeetingExport.write(meeting, directory: root, to: bundle)
        let replaced = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("info.json")))
                as? [String: Any])
        #expect(replaced["other.editor"] != nil)
        let invalidMetadata = Data("invalid metadata".utf8)
        try invalidMetadata.write(to: bundle.appendingPathComponent("info.json"))
        #expect(throws: (any Error).self) { try MeetingExport.write(meeting, directory: root, to: bundle) }
        #expect(try Data(contentsOf: bundle.appendingPathComponent("info.json")) == invalidMetadata)
    }

    @Test func jsonSidecarRoundTripsThroughMeetingImportAndAvoidsExistingAssets() throws {
        let (root, meeting) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meeting.json")
        try MeetingExport.write(meeting, directory: root, to: file)
        try MeetingExport.write(meeting, directory: root, to: file)
        let data = try Data(contentsOf: file)
        #expect(String(decoding: data, as: UTF8.self).contains("meeting-assets-2"))
        let renamed = root.appendingPathComponent("renamed.json")
        try FileManager.default.moveItem(at: file, to: renamed)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("imported-library"))
        try store.importArchive(url: renamed)
        let imported = try #require(store.meetings.first)
        #expect(imported.notes == meeting.notes)
        #expect(imported.audioFiles.isEmpty)
        #expect(
            try Data(contentsOf: store.directory(for: imported.id).appendingPathComponent("assets/original.png")) == png
        )
    }

    @Test func exportRegeneratesMissingManagedPreviewFromOriginal() throws {
        let fixtures = NotesImageTests()
        let root = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "original.png", directory: root)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, alt: "Diagram")
        let resized = try NotesImageStore.resized(original, width: 80, directory: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(resized.displayPath))
        let bundle = root.appendingPathComponent("regenerated.textbundle")
        try MeetingExport.write(Meeting(title: "Diagram", notes: resized.markdown), directory: root, to: bundle)
        #expect(try NotesImageStore.info(at: bundle.appendingPathComponent(resized.displayPath)).pixelWidth == 160)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("assets").path).count == 2
        )
        #expect(
            try Data(contentsOf: bundle.appendingPathComponent(path))
                == Data(contentsOf: root.appendingPathComponent(path)))
    }

    @Test func importRejectsSidecarTraversalAndSymlinksWithoutAddingMeeting() throws {
        let (root, meeting) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meeting.json")
        try MeetingExport.write(meeting, directory: root, to: file)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["notesAssets"] = [
            "assets/original.png": "../original.png", "assets/display.png": "meeting-assets/display.png",
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("imported-library"))
        #expect(throws: (any Error).self) { try store.importArchive(url: file) }
        #expect(store.meetings.isEmpty)
        try MeetingExport.write(meeting, directory: root, to: file)
        let sidecar = root.appendingPathComponent("meeting-assets-2")
        try FileManager.default.removeItem(at: sidecar.appendingPathComponent("display.png"))
        try FileManager.default.createSymbolicLink(
            at: sidecar.appendingPathComponent("display.png"),
            withDestinationURL: root.appendingPathComponent("assets/display.png"))
        #expect(throws: (any Error).self) { try store.importArchive(url: file) }
        #expect(store.meetings.isEmpty)
    }

    @Test func legacyImageJSONKeepsTextAndReportsMissingAttachments() throws {
        let (root, meeting) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(meeting).write(to: file)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("imported-library"))
        try store.importArchive(url: file)
        #expect(store.meetings.first?.notes == meeting.notes)
        #expect(store.errorMessage?.contains("images in notes were not imported") == true)
    }

    @Test func archiveHashIncludesImageBytesAndRequestLimitIsEncodedSize() throws {
        let (root, meeting) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ArchiveNoteImages.artifacts(notes: meeting.notes, directory: root)
        let firstSnapshot = try ArchiveNoteImages.requestData(["artifacts": first, "notes": meeting.notes])
        var changed = png
        changed.append(Data("another image revision".utf8))
        try changed.write(to: root.appendingPathComponent("assets/original.png"))
        let second = try ArchiveNoteImages.artifacts(notes: meeting.notes, directory: root)
        let secondSnapshot = try ArchiveNoteImages.requestData(["artifacts": second, "notes": meeting.notes])
        #expect(
            ArchiveNoteImages.importKey(snapshot: firstSnapshot, audio: [])
                != ArchiveNoteImages.importKey(snapshot: secondSnapshot, audio: []))
        #expect(
            try ArchiveNoteImages.requestData([
                "notes": String(repeating: "x", count: ArchiveNoteImages.maximumRequestBytes - 12)
            ]).count <= ArchiveNoteImages.maximumRequestBytes)
        #expect(throws: (any Error).self) {
            try ArchiveNoteImages.requestData([
                "notes": String(repeating: "x", count: ArchiveNoteImages.maximumRequestBytes)
            ])
        }
        let legacy = try JSONDecoder().decode(
            ArchiveCheckpoint.self,
            from: Data(
                #"{"origin":"https://example.invalid","externalID":"x","importKey":"x","snapshot":"e30=","audio":[]}"#
                    .utf8))
        #expect(legacy.omittedNoteImages == nil)
    }
}
