import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import GdayMeetings

@Suite struct NotesImageTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func png(width: Int = 400, height: Int = 200, dpi: Double = 144, alpha: CGFloat = 0.5) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func referenceRoundTripAndScopedRewrite() throws {
        let reference = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: "assets/a b.png", displayPath: "assets/a-small.png",
            width: 120, alt: "A \"quote\" & detail")
        let parsed = try #require(NotesImageReference.parse(in: reference.markdown).first)
        #expect(parsed.originalPath == reference.originalPath)
        #expect(parsed.alt == reference.alt)
        #expect(parsed.width == 120)
        let text =
            "assets/a b.png\n" + reference.markdown
            + "\n<a href=\"chapter.html\">Chapter</a>\n```\n![code](assets/code.png)\n```"
        #expect(NotesAssets.tokens(in: text).map(\.path) == ["assets/a b.png", "assets/a-small.png"])
        let rewritten = NotesAssets.rewritingReferences(in: text, paths: ["assets/a b.png": "export-assets/a b.png"])
        #expect(rewritten.hasPrefix("assets/a b.png\n"))
        #expect(rewritten.contains("href=\"export-assets/a%20b.png\""))
        var plain = reference
        plain.width = nil
        plain.alt = "Brackets [detail] \\ source"
        #expect(NotesImageReference.parse(in: plain.markdown).first?.alt == plain.alt)
    }
    @Test func rejectsTraversalAndDanglingParentSymlink() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside.png", "assets/../outside.png", "assets//a.png", "assets/a\\b.png"] {
            #expect(throws: (any Error).self) { try NotesAssets.safeURL(relativePath: path, directory: root) }
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("assets"),
            withDestinationURL: root.appendingPathComponent("missing/outside"))
        #expect(throws: (any Error).self) { try NotesAssets.safeURL(relativePath: "assets/image.png", directory: root) }
        #expect(throws: (any Error).self) {
            try NotesImageStore.write(Data([1]), filename: "image.png", directory: root)
        }
    }
    @Test func originalBytesDPIReuseAndResizing() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try png()
        let original = root.appendingPathComponent("Diagram wrong.jpg")
        try bytes.write(to: original)
        let reference = try NotesImageStore.importFile(original, directory: root)
        #expect(reference.originalPath == "assets/diagram-wrong.png")
        let url = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: root)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try NotesImageStore.importFile(original, directory: root).originalPath == reference.originalPath)
        let info = try NotesImageStore.info(at: url)
        #expect(abs(info.naturalSize.width - 200) < 1)
        let resized = try NotesImageStore.resized(reference, width: 80, directory: root)
        #expect(resized.displayPath != reference.originalPath)
        #expect(resized.displayPath.hasSuffix(".png"))
        let small = try NotesAssets.safeURL(relativePath: resized.displayPath, directory: root)
        #expect(try NotesImageStore.info(at: small).pixelWidth == 160)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try NotesImageStore.resized(resized, width: nil, directory: root).displayPath == reference.originalPath)
    }
    @Test func cleanupRetainsMalformedAndFencedReferences() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["keep.png", "code.png", "orphan.png"] {
            try NotesImageStore.write(Data([1]), filename: name, directory: root)
        }
        var removed: [String] = []
        try NotesImageStore.cleanup(
            directory: root, markdown: "<img weird='assets/keep.png'>\n```\nassets/code.png\n```",
            trash: { removed.append($0.lastPathComponent) })
        #expect(removed == ["orphan.png"])
    }
    @Test func crossMeetingCopyPreservesBytesAndResolvesCollision() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let first = try png()
        let other = try png(width: 120)
        try NotesImageStore.write(first, filename: "diagram.png", directory: source)
        try NotesImageStore.write(other, filename: "diagram.png", directory: target)
        let copied = try NotesImageClipboard.copyAssets(in: "![Diagram](assets/diagram.png)", from: source, to: target)
        #expect(copied == "![Diagram](assets/diagram-2.png)")
        #expect(try Data(contentsOf: target.appendingPathComponent("assets/diagram-2.png")) == first)
        #expect(try Data(contentsOf: target.appendingPathComponent("assets/diagram.png")) == other)
    }

}

extension NotesImageTests {
    @Test func conflictBackupRetainsImage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try png()
        try NotesImageStore.write(bytes, filename: "backup.png", directory: root)
        try "![Backup](assets/backup.png)".write(
            to: root.appendingPathComponent("notes (changed on disk).md"), atomically: true, encoding: .utf8)
        try NotesImageClipboard.cleanupSaved(directory: root, markdown: "No image in current notes")
        #expect(try Data(contentsOf: root.appendingPathComponent("assets/backup.png")) == bytes)
    }
}

@MainActor struct NotesImageEditorTests {
    @Test func imagePasteResizeAndUndoPreserveTextTimesAndAssets() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let root = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.allowsUndo = true
        text.undoManager?.groupsByEvent = false
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { 25 }, canPlay: { false }, play: { _ in },
            changed: { _ in }, flush: {}, directory: root)
        text.load("")
        text.delegate = text
        text.textStorage?.delegate = text
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try fixtures.png(), forType: .png)
        text.notesPasteboard = pasteboard
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NotesTextView.paste(_:)), keyEquivalent: "v")
        #expect(text.validateMenuItem(pasteItem))
        #expect(text.readablePasteboardTypes.contains(.png))
        text.undoManager?.beginUndoGrouping()
        text.paste(nil)
        text.undoManager?.endUndoGrouping()
        let original = text.document.markdown
        #expect(text.document.lines[0].time == 25)
        let reference = try #require(NotesImageReference.parse(in: text.string).first)
        let file = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: root)
        #expect(FileManager.default.fileExists(atPath: file.path))
        text.undoManager?.beginUndoGrouping()
        text.resizeImage(reference, width: 80)
        text.undoManager?.endUndoGrouping()
        #expect(text.string.contains("width=\"80\""))
        #expect(text.document.lines[0].time == 25)
        text.undoManager?.undo()
        #expect(text.document.markdown == original)
        #expect(text.string == text.document.text)
        #expect(FileManager.default.fileExists(atPath: file.path))
        text.undoManager?.redo()
        #expect(text.string.contains("width=\"80\""))
        text.load("Externally replaced")
        #expect(text.undoManager?.canUndo == false)
    }
}

extension NotesImageEditorTests {
    @Test func pauseAddsPhraseTimeButTypingAndCorrectionsDoNot() {
        _ = NSApplication.shared
        let text = NotesTextView(usingTextLayoutManager: true)
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { 50 }, canPlay: { false }, play: { _ in },
            changed: { _ in }, flush: {})
        text.load("First <!-- gday:t=0:10 -->")
        text.delegate = text
        text.lastInsertionDate = Date().addingTimeInterval(-16)
        text.insertText(" second", replacementRange: NSRange(location: 5, length: 0))
        #expect(text.document.time(at: 8) == 50)
        text.lastInsertionDate = Date().addingTimeInterval(-16)
        text.insertText("i", replacementRange: NSRange(location: 1, length: 1))
        #expect(text.document.time(at: 1) == 10)
        text.load("Another <!-- gday:t=0:05 -->")
        #expect(text.lastInsertionDate == nil)
    }
}

extension NotesImageEditorTests {
    @Test func deferredWidthCopyPreservesCaretTimelineAndUndo() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let root = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: root)
        let reference = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, width: 80, alt: "Diagram")
        let original = reference.markdown + " <!-- gday:t=0:20 -->\nTail <!-- gday:t=0:40 -->"
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.allowsUndo = true
        text.undoManager?.groupsByEvent = false
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: original, editable: true, clock: { 90 }, canPlay: { false }, play: { _ in },
            changed: { _ in }, flush: {}, directory: root)
        text.load(original)
        text.delegate = text
        text.textStorage?.delegate = text
        text.setSelectedRange((text.string as NSString).range(of: "Tail"))
        text.undoManager?.beginUndoGrouping()
        text.normalizeImageWidths()
        text.undoManager?.endUndoGrouping()
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "Tail")
        #expect(text.document.time(at: text.selectedRange().location) == 40)
        #expect(text.string.contains("gday-preview-"))
        text.undoManager?.undo()
        #expect(text.document.markdown == original)
        #expect(text.document.text == text.string)
    }
}

extension NotesImageTests {
    @Test func repeatedResizesKeepOnePreviewAndUndoRegenerates() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalPath = try NotesImageStore.write(png(), filename: "original.png", directory: root)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: originalPath, displayPath: originalPath, alt: "Diagram")
        let small = try NotesImageStore.resized(original, width: 50, directory: root)
        let larger = try NotesImageStore.resized(small, width: 120, directory: root)
        #expect(small.displayPath == larger.displayPath)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path).count == 2)
        let preview = try NotesAssets.safeURL(relativePath: small.displayPath, directory: root)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 240)
        try NotesImageStore.ensurePreviews(in: small.markdown, directory: root)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 100)
        try NotesImageStore.ensurePreviews(in: small.markdown + "\n" + larger.markdown, directory: root)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 240)
        try NotesImageStore.cleanupManagedPreviews(in: original.markdown, directory: root)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(originalPath).path))
        try NotesImageStore.ensurePreviews(in: small.markdown, directory: root)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 100)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path).count == 2)
    }
    @Test func importedPreviewRebuildsOwnershipAndKeepsStablePath() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let path = try NotesImageStore.write(png(), filename: "original.png", directory: source)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, alt: "Diagram")
        let first = try NotesImageStore.resized(original, width: 50, directory: source)
        let copied = try NotesImageClipboard.copyAssets(in: first.markdown, from: source, to: target)
        #expect(
            !FileManager.default.fileExists(atPath: target.appendingPathComponent("notes-image-previews.json").path))
        let imported = try #require(NotesImageReference.parse(in: copied).first)
        let resized = try NotesImageStore.resized(imported, width: 100, directory: target)
        #expect(imported.displayPath == resized.displayPath)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("assets").path).count == 2
        )
    }
    @Test func failedPreviewReplacementRetainsPriorBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(png(), filename: "original.png", directory: root)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, alt: "Diagram")
        let first = try NotesImageStore.resized(original, width: 50, directory: root)
        let preview = try NotesAssets.safeURL(relativePath: first.displayPath, directory: root)
        let bytes = try Data(contentsOf: preview)
        let index = root.appendingPathComponent("notes-image-previews.json")
        let savedIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try NotesImageStore.resized(first, width: 100, directory: root) }
        #expect(try Data(contentsOf: preview) == bytes)
        try FileManager.default.removeItem(at: index)
        try savedIndex.write(to: index)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 100)
    }
}

extension NotesImageTests {
    @Test func twoImportedPreviewsBecomeOneAndCorruptIndexCannotOverwriteOriginal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(png(), filename: "original.png", directory: root)
        let firstPath = try NotesImageStore.write(
            png(width: 100, height: 50), filename: "gday-preview-\(UUID().uuidString).png", directory: root)
        let secondPath = try NotesImageStore.write(
            png(width: 240, height: 120), filename: "gday-preview-\(UUID().uuidString).png", directory: root)
        let first = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: firstPath, width: 50, alt: "Small")
        let second = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: secondPath, width: 120, alt: "Large")
        let canonical = try NotesImageStore.canonicalizedNotes(
            in: first.markdown + "\n" + second.markdown, directory: root)
        let references = NotesImageReference.parse(in: canonical)
        #expect(references.count == 2)
        #expect(references[0].displayPath == references[1].displayPath)
        try canonical.write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try NotesImageStore.cleanupManagedPreviews(in: canonical, directory: root)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path).count == 2)
        let surviving = try NotesAssets.safeURL(relativePath: references[0].displayPath, directory: root)
        #expect(try NotesImageStore.info(at: surviving).pixelWidth == 240)
        let before = try Data(contentsOf: surviving)
        let index: [String: Any] = [
            "files": [
                path: references[0].displayPath,
                references[0].displayPath: "assets/gday-preview-\(UUID().uuidString).png",
            ]
        ]
        try JSONSerialization.data(withJSONObject: index).write(
            to: root.appendingPathComponent("notes-image-previews.json"))
        #expect(throws: (any Error).self) { try NotesImageStore.resized(references[0], width: 80, directory: root) }
        #expect(try Data(contentsOf: surviving) == before)
        #expect(!NotesImageStore.isManagedPreview("assets/gday-preview-not-a-uuid.png"))
        #expect(!NotesImageStore.isManagedPreview("assets/gday-preview-\(UUID().uuidString)/other.png"))
    }
}

extension NotesImageTests {
    @Test func replacedOriginalAtSameDimensionsRefreshesPreview() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(png(), filename: "original.png", directory: root)
        let original = NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path, alt: "Diagram")
        let reference = try NotesImageStore.resized(original, width: 80, directory: root)
        let preview = try NotesAssets.safeURL(relativePath: reference.displayPath, directory: root)
        let before = try Data(contentsOf: preview)
        let originalURL = root.appendingPathComponent(path)
        try png(alpha: 1).write(to: originalURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: originalURL.path)
        try NotesImageStore.ensurePreviews(in: reference.markdown, directory: root)
        #expect(try Data(contentsOf: preview) != before)
        #expect(try NotesImageStore.info(at: preview).pixelWidth == 160)
    }
}

extension NotesImageEditorTests {
    @Test func mountedMultilineReplacementScrollDeleteAndUndoKeepLayoutCoherent() throws {
        _ = NSApplication.shared
        let fixtures = NotesImageTests()
        let root = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let text = NotesTextView(usingTextLayoutManager: true)
        text.frame = scroll.bounds
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.allowsUndo = true
        scroll.documentView = text
        window.contentView = scroll
        window.makeFirstResponder(text)
        text.undoManager?.groupsByEvent = false
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { 25 }, canPlay: { false }, play: { _ in },
            changed: { _ in }, flush: {}, directory: root)
        text.load("![First](\(path))\nTail")
        text.delegate = text
        text.textStorage?.delegate = text
        text.prepareImageLayout()
        window.layoutIfNeeded()
        let long = String(repeating: "Line 😀\n", count: 30) + "![Last image](\(path))"
        text.undoManager?.beginUndoGrouping()
        text.insertText(long, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        text.undoManager?.endUndoGrouping()
        text.prepareImageLayout()
        text.layout()
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
        window.layoutIfNeeded()
        text.layout()
        #expect(text.images.views.count == 1)
        #expect(text.images.views.first?.isHidden == false)
        text.undoManager?.beginUndoGrouping()
        text.insertText("Short", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        text.undoManager?.endUndoGrouping()
        text.prepareImageLayout()
        text.layout()
        #expect(text.images.views.isEmpty)
        text.undoManager?.undo()
        text.prepareImageLayout()
        text.layout()
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
        text.layout()
        #expect(text.string == long)
        #expect(text.document.text == long)
        text.undoManager?.redo()
        text.prepareImageLayout()
        text.layout()
        #expect(text.string == "Short")
        let linked = "<a href=\"\(path)\"><img src=\"\(path)\" width=\"80\" alt=\"Diagram\"></a>"
        text.load(linked)
        text.prepareImageLayout()
        text.layout()
        let start = (text.string as NSString).range(of: "<img").location
        text.undoManager?.beginUndoGrouping()
        text.insertText(
            "", replacementRange: NSRange(location: start, length: (text.string as NSString).length - start))
        text.undoManager?.endUndoGrouping()
        // Layout can arrive before the queued decoration refresh after a deletion.
        text.layout()
        let allHidden = text.images.views.allSatisfy { $0.isHidden }
        #expect(allHidden)
        text.prepareImageLayout()
        text.layout()
        #expect(text.images.views.isEmpty)
        #expect(text.string == "<a href=\"\(path)\">")
        text.undoManager?.undo()
        text.prepareImageLayout()
        text.layout()
        #expect(text.string == linked)
        #expect(text.images.views.count == 1)
    }
}

extension NotesImageEditorTests {
    @Test func typingKeepsImageIdentityAndVisibilityAcrossDeferredLayout() throws {
        _ = NSApplication.shared
        let fixture = NotesImageTests()
        let directory = try fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try NotesImageStore.write(fixture.png(), filename: "diagram.png", directory: directory)
        let text = NotesTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        text.allowsUndo = true
        text.undoManager?.groupsByEvent = false
        text.editor = MarkdownNotesEditor(
            meetingID: UUID(), markdown: "", editable: true, clock: { nil }, canPlay: { false }, play: { _ in },
            changed: { _ in }, flush: {}, directory: directory)
        text.load("![Diagram](\(path))\nFollowing text")
        text.delegate = text
        text.prepareImageLayout()
        text.layout()
        let image = try #require(text.images.views.first)
        let bitmap = image.image
        #expect(!image.isHidden)
        text.undoManager?.beginUndoGrouping()
        text.insertText(image.reference.markdown, replacementRange: image.reference.range)
        for letter in " more words" {
            text.insertText(
                String(letter), replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
            text.layout()
            #expect(text.images.views.first === image)
            #expect(image.superview === text)
            #expect(!image.isHidden)
            text.prepareImageLayout()
            text.layout()
            #expect(text.images.views.first === image)
            #expect(image.image === bitmap)
            #expect(!image.isHidden)
        }
        text.insertText("Before\n", replacementRange: NSRange(location: 0, length: 0))
        text.layout()
        #expect(text.images.views.first === image)
        #expect(image.reference.range.location == 7)
        text.undoManager?.endUndoGrouping()
        text.prepareImageLayout()
        text.layout()
        #expect(!image.isHidden)
        text.undoManager?.beginUndoGrouping()
        text.insertText("", replacementRange: image.reference.range)
        text.undoManager?.endUndoGrouping()
        text.layout()
        #expect(text.images.views.isEmpty)
        text.prepareImageLayout()
        text.undoManager?.undo()
        text.prepareImageLayout()
        text.layout()
        #expect(text.images.views.count == 1)
        #expect(text.images.views.first?.isHidden == false)

        let markup = "![Diagram](\(path))"
        text.load(markup + "\n" + markup + "\nFollowing")
        text.prepareImageLayout()
        text.layout()
        let second = try #require(text.images.views.last)
        text.undoManager?.beginUndoGrouping()
        text.insertText("", replacementRange: NSRange(location: 0, length: markup.utf16.count + 1))
        text.undoManager?.endUndoGrouping()
        text.layout()
        #expect(text.images.views.first === second)
        text.prepareImageLayout()
        text.layout()
        #expect(text.images.views.first === second)

        text.load(markup)
        text.prepareImageLayout()
        text.layout()
        let endingImage = try #require(text.images.views.first)
        text.undoManager?.beginUndoGrouping()
        text.insertText("\nTyping after Return", replacementRange: NSRange(location: markup.utf16.count, length: 0))
        text.undoManager?.endUndoGrouping()
        text.layout()
        #expect(text.images.views.first === endingImage)
        text.prepareImageLayout()
        text.layout()
        let tail = (text.string as NSString).range(of: "Typing")
        let paragraph =
            text.textStorage?.attribute(.paragraphStyle, at: tail.location, effectiveRange: nil) as? NSParagraphStyle
        #expect((paragraph?.paragraphSpacing ?? 0) == 0)
        #expect(text.images.views.first === endingImage)
        #expect(!endingImage.isHidden)
    }
}
