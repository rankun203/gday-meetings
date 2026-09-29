import AppKit
import Testing

@testable import GdayMeetings

@MainActor @Suite(.serialized)
struct MarkdownBlockGeometryTests {
    @Test func codePlaceholdersKeepListMarkers() {
        let document = NotesReadingDocument(
            "- Read `meetings/<UUID>/`.\n- Match `people/<personID>.json`.\n- Ordinary item.")
        #expect(document.blocks.count == 3)
        for block in document.blocks {
            guard case .list(_, let marker) = block.content else {
                Issue.record("Code placeholders must not turn a list item into literal text")
                continue
            }
            #expect(marker == "•")
        }
    }

    @Test func fencedBackgroundSurvivesScrollingThroughLongDocument() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let text = MarkdownReadingTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 600, height: 10000)
        text.textContainer?.containerSize = NSSize(width: 564, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        scroll.documentView = text
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let source = (0..<8).map { index in
            "## Section \(index)\n\n```sh\n" + (0..<12).map { "echo example-\(index)-\($0)" }.joined(separator: "\n")
                + "\n```\n"
        }.joined(separator: "\n")
        text.textStorage!.setAttributedString(
            MarkdownReadingRenderer.render(
                source, timestamps: false, emptyMessage: "", directory: URL(fileURLWithPath: "/tmp"),
                interactiveTasks: false))
        text.refreshTaskRanges()
        for index in [0, 3, 7, 1] {
            let range = (text.string as NSString).range(of: "echo example-\(index)-0")
            let glyph = try #require(text.textRangeRects(range).first)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: glyph.minY + 10))
            let region = try #require(text.codeRegions().first { $0.body.hasPrefix("echo example-\(index)-0") })
            #expect(region.frame.minY <= glyph.minY)
            let end = (text.string as NSString).range(of: "echo example-\(index)-11")
            let last = try #require(text.textRangeRects(end).last)
            #expect(region.frame.maxY >= last.maxY)
            #expect(region.frame.height > 150)
        }
    }
}
