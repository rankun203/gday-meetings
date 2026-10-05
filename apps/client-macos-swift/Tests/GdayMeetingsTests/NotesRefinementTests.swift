import Foundation
import Testing

@testable import GdayMeetings

struct NotesPhraseTests {
    @Test func multipleMarkersRoundTripAndSeekByPhrase() {
        let raw = "First <!-- gday:t=0:10 --> second <!-- gday:t=0:30 -->"
        let value = NotesDocument(raw)
        #expect(value.text == "First second")
        #expect(value.markdown == raw)
        #expect(value.time(at: 2) == 10)
        #expect(value.time(at: 8) == 30)
        #expect(value.citedText == "[0:10] First[0:30]  second")
    }
    @Test func appendPauseAddsMarkerAndTypoPreservesIt() {
        var value = NotesDocument("First <!-- gday:t=0:10 -->")
        value.replace(NSRange(location: 5, length: 0), with: " second", clock: 30, phraseClock: 30)
        #expect(value.markdown == "First <!-- gday:t=0:10 --> second <!-- gday:t=0:30 -->")
        value.replace(NSRange(location: 7, length: 1), with: "E", clock: 80, phraseClock: 80)
        #expect(value.time(at: 8) == 30)
        #expect(value.markdown.contains("gday:t=0:30"))
        value.replace(NSRange(location: value.text.utf16.count, length: 0), with: "!", clock: 81)
        #expect(value.markdown.hasSuffix("second! <!-- gday:t=0:30 -->") == false)
        #expect(value.markdown.contains("sEcond! <!-- gday:t=0:30 -->"))
        #expect(NotesDocument(value.markdown).text == value.text)
    }
    @Test func phraseSplitPreservesBothHalvesAndCodeLiteral() {
        var value = NotesDocument("First <!-- gday:t=0:10 --> second <!-- gday:t=0:30 -->")
        value.replace(NSRange(location: 8, length: 0), with: "\n", clock: 100)
        let reopened = NotesDocument(value.markdown)
        #expect(reopened.text == value.text)
        #expect(reopened.lines.last?.time == 30)
        let code = "```\ncomment <!-- gday:t=0:10 -->\n```"
        #expect(NotesDocument(code).text == code)
    }
}

@MainActor struct NotesWatchTests {
    @Test func externalReplacementAndPendingConflict() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = NotesStorage(directory: folder)
        let id = UUID()
        try await storage.write(id, text: "Original")
        try Data("External".utf8).write(to: storage.url(id), options: .atomic)
        #expect(try await storage.reloadExternal(id) == "External")
        #expect(try await storage.reloadExternal(id) == nil)
        storage.schedule(id, text: "App draft")
        try Data("Another external edit".utf8).write(to: storage.url(id), options: .atomic)
        #expect(try await storage.reloadExternal(id) == nil)
        #expect(try String(contentsOf: storage.url(id), encoding: .utf8) == "App draft")
        let backup = storage.url(id).deletingLastPathComponent().appendingPathComponent("notes (changed on disk).md")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "Another external edit")
    }
    @Test func watchesAtomicReplacementAndRecreationThenStops() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = NotesStorage(directory: folder)
        let id = UUID()
        try await storage.write(id, text: "Original")
        var updates: [String] = []
        try await storage.watch(id) { updates.append($0) }
        try Data("Atomic".utf8).write(to: storage.url(id), options: .atomic)
        for _ in 0..<30 where updates.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(updates == ["Atomic"])
        try FileManager.default.removeItem(at: storage.url(id))
        try await Task.sleep(for: .milliseconds(180))
        #expect(updates == ["Atomic"])
        try Data("Recreated".utf8).write(to: storage.url(id), options: .atomic)
        for _ in 0..<30 where updates.count == 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(updates == ["Atomic", "Recreated"])
        try Data("Ignore after close".utf8).write(to: storage.url(id), options: .atomic)
        storage.stopWatching(id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(updates.count == 2)
    }
}

struct NotesReadingTests {
    @Test func tableCellsPreserveEscapedAndCodePipes() {
        #expect(NotesReadingDocument.cells("| a\\|b | `x|y` |") == ["a\\|b", "`x|y`"])
        let document = NotesReadingDocument("<!-- gday:t=0:12 -->\n| Name | Count |\n| :--- | ---: |\n| **One** | 2 |")
        #expect(document.blocks.count == 1)
        #expect(document.blocks.first?.time == 12)
        guard case .table(let rows, let alignment) = document.blocks.first?.content else {
            Issue.record("Expected a reading table")
            return
        }
        #expect(rows == [["Name", "Count"], ["**One**", "2"]])
        #expect(alignment.count == 2)
    }
    @Test func readingRecognizesBlocksWithoutChangingSource() {
        let markdown =
            "# Heading\n- [x] Finished\n> Quote\n```swift\nlet text = \"**literal**\"\n```\n![Chart](assets/chart.png)"
        let document = NotesReadingDocument(markdown)
        #expect(document.blocks.count == 5)
        guard case .code(let text) = document.blocks[3].content else {
            Issue.record("Expected literal code")
            return
        }
        #expect(text == "let text = \"**literal**\"")
        guard case .image(let image) = document.blocks[4].content else {
            Issue.record("Expected local image")
            return
        }
        #expect(image.originalPath == "assets/chart.png")
    }
}

extension NotesPhraseTests {
    @Test func emojiEditsDeleteAndSplitKeepValidOffsets() {
        var value = NotesDocument("🙂 First <!-- gday:t=0:10 --> café <!-- gday:t=0:30 -->")
        value.replace(NSRange(location: 0, length: 2), with: "👩‍💻", clock: 99)
        #expect(NotesDocument(value.markdown).text == value.text)
        let target = (value.text as NSString).range(of: "café")
        #expect(value.time(at: target.location) == 30)
        value.replace(target, with: "", clock: 100)
        #expect(NotesDocument(value.markdown).text == value.text)
        #expect(!value.markdown.contains("gday:t=1:40"))
        #expect(NotesDocument("`<!-- gday:t=0:10 -->`").text == "`<!-- gday:t=0:10 -->`")
    }
}

extension NotesReadingTests {
    @Test func mixedImagesAndMalformedTablesRemainVisible() {
        for line in ["Before ![One](assets/one.png) after", "![One](assets/one.png) ![Two](assets/two.png)"] {
            guard case .literal(let text) = NotesReadingDocument(line).blocks.first?.content else {
                Issue.record("Mixed image content must remain visible")
                continue
            }
            #expect(text == line)
        }
        let malformed = NotesReadingDocument("| Name | Count |\n| -- | no |\n| One | 2 |")
        #expect(malformed.blocks.count == 3)
        for block in malformed.blocks {
            if case .table = block.content { Issue.record("Malformed delimiter must remain text") }
        }
    }
}

extension NotesWatchTests {
    @Test func switchingMeetingsIgnoresQueuedOldEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = NotesStorage(directory: folder)
        let old = UUID()
        let current = UUID()
        try await storage.write(old, text: "Old")
        try await storage.write(current, text: "Current")
        var oldEvents = 0
        var currentEvents: [String] = []
        try await storage.watch(old) { _ in oldEvents += 1 }
        try Data("Queued old edit".utf8).write(to: storage.url(old), options: .atomic)
        try await storage.watch(current) { currentEvents.append($0) }
        try Data("New meeting edit".utf8).write(to: storage.url(current), options: .atomic)
        for _ in 0..<30 where currentEvents.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(oldEvents == 0)
        #expect(currentEvents == ["New meeting edit"])
        storage.stopWatching(current)
    }
}

extension NotesPhraseTests {
    @Test func privateClipboardSlicesAndPastesPhraseTimes() {
        let source = NotesDocument("First <!-- gday:t=0:10 --> second <!-- gday:t=0:30 -->")
        let copied = source.slice(NSRange(location: 2, length: 8))
        #expect(copied.text == "rst seco")
        #expect(copied.time(at: 0) == 10)
        #expect(copied.time(at: 6) == 30)
        var target = NotesDocument("Before <!-- gday:t=0:50 -->")
        target.replace(NSRange(location: 6, length: 0), with: copied.text, clock: 99)
        target.applyCopiedTimes(copied, at: 6)
        let reopened = NotesDocument(target.markdown)
        #expect(reopened.text == "Beforerst seco")
        #expect(reopened.time(at: 0) == 50)
        #expect(reopened.time(at: 7) == 10)
        #expect(reopened.time(at: 12) == 30)
    }
}

extension NotesPhraseTests {
    @Test func longerFenceCloseRestoresTimingParsing() {
        let raw = "```swift\nlet value = 1\n````\nAfter <!-- gday:t=0:30 -->"
        let value = NotesDocument(raw)
        #expect(value.markdown == raw)
        #expect(value.lines.last?.time == 30)
        #expect(value.lines.last?.text == "After")
    }
}

extension NotesPhraseTests {
    @Test func deletingWholePhraseOrLineRemovesItsMarkers() {
        let source = "First <!-- gday:t=0:10 --> second <!-- gday:t=0:30 -->"
        var value = NotesDocument(source)
        value.replace(NSRange(location: 0, length: value.text.utf16.count), with: "", clock: nil)
        #expect(value.markdown.isEmpty)
        #expect(value.lines.first?.time == nil)
        value = NotesDocument(source)
        value.replace(NSRange(location: 0, length: 5), with: "", clock: nil)
        #expect(!value.markdown.contains("gday:t=0:10"))
        #expect(NotesDocument(value.markdown).time(at: 1) == 30)
    }
}

extension NotesReadingTests {
    @Test func unsupportedHtmlAndNestedBlocksKeepLiteralStructure() {
        for source in [
            "  - Nested item", "    indented block", "Before <span>HTML</span> after", "\tCode indentation",
            "    ![Code](assets/code.png)",
        ] {
            guard case .literal(let visible) = NotesReadingDocument(source).blocks.first?.content else {
                Issue.record("Unsupported block syntax must stay visible")
                continue
            }
            #expect(visible == source)
        }
    }
}
