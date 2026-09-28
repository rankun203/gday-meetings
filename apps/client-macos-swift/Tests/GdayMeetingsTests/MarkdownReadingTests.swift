import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct MarkdownReadingTests {
    @Test func repeatedTaskTogglesPreserveViewportSelectionAndHover() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let text = MarkdownReadingTextView(usingTextLayoutManager: true)
        text.frame = scroll.bounds
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 18, height: 16)
        scroll.documentView = text
        window.contentView = scroll
        let markdown =
            "| Topic | Decision |\n| --- | --- |\n| Release | Friday |\n\n"
            + (0..<35).map { "- [ ] **Person \($0)**: " + String(repeating: "检查订单与环境配置。 ", count: 5) + "[00:12]" }
            .joined(separator: "\n")
        text.source = markdown
        text.interactiveTasks = true
        text.directory = URL(fileURLWithPath: "/tmp")
        text.textStorage!.setAttributedString(
            MarkdownReadingRenderer.render(
                markdown, timestamps: false, emptyMessage: "", directory: text.directory!, interactiveTasks: true))
        text.refreshTaskRanges()
        window.contentView?.layoutSubtreeIfNeeded()
        text.textLayoutManager?.ensureLayout(for: text.textLayoutManager!.documentRange)
        text.sizeToFit()
        // Finish the initial size-to-fit invalidation before comparing subsequent edits.
        window.contentView?.layoutSubtreeIfNeeded()
        text.textLayoutManager?.ensureLayout(for: text.textLayoutManager!.documentRange)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 650))
        let row = try #require(text.taskRegions().first(where: { $0.frame.minY >= text.visibleRect.minY }))
        let point = NSPoint(x: row.frame.midX, y: row.frame.midY)
        text.updateHover(at: point)
        let selected = (text.string as NSString).range(of: "Person 8")
        text.setSelectedRange(selected)
        let origin = scroll.contentView.bounds.origin
        let display = text.string
        // TextKit 2 may refine its estimated document frame as offscreen fragments
        // are visited. Compare actual laid-out text geometry, not that estimate.
        let endRange = NSRange(location: text.string.utf16.count - 2, length: 1)
        let lastLine = text.firstRect(forCharacterRange: endRange, actualRange: nil)
        for _ in 0..<6 {
            let next = MarkdownReadingRenderer.togglingTask(in: text.source!, line: row.line)
            #expect(text.applyTaskToggle(next))
            window.contentView?.layoutSubtreeIfNeeded()
            text.textLayoutManager?.ensureLayout(for: text.textLayoutManager!.documentRange)
            #expect(text.string == display)
            #expect(text.selectedRange() == selected)
            #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
            #expect(abs(text.firstRect(forCharacterRange: endRange, actualRange: nil).minY - lastLine.minY) < 1)
            #expect(text.hoverLine == row.line)
            let updated = try #require(text.taskRegions().first(where: { $0.line == row.line }))
            #expect(abs(updated.frame.minY - row.frame.minY) < 1)
            var taskLocation: Int?
            text.textStorage!.enumerateAttribute(
                .markdownTaskLine, in: NSRange(location: 0, length: text.string.utf16.count)
            ) { value, range, stop in
                if value as? Int == row.line {
                    taskLocation = range.location
                    stop.pointee = true
                }
            }
            let marker = try #require(taskLocation)
            let strike =
                text.textStorage!.attribute(
                    .strikethroughStyle, at: marker + 2, effectiveRange: nil) as? Int
            #expect((strike == NSUnderlineStyle.single.rawValue) == updated.checked)
            #expect(
                MarkdownReadingSelectionCopy.markdown(
                    from: text.textStorage!, selection: NSRange(location: 0, length: text.string.utf16.count)
                ).contains(next.components(separatedBy: "\n")[row.line]))
            // Cursor-update and entry events must restore hover after it is cleared on exit.
            text.updateHover(at: NSPoint(x: -100, y: -100))
            #expect(text.hoverLine == nil)
            text.updateHover(at: point)
            #expect(text.hoverLine == row.line)
        }
        #expect(!text.applyTaskToggle(text.source! + "\nNew paragraph"))
    }
    @Test func citationsSupportLongMinutesAndHours() {
        #expect(MarkdownReadingRenderer.citationTime("81:32") == 4892)
        #expect(MarkdownReadingRenderer.citationTime("1:21:32") == 4892)
        #expect(MarkdownReadingRenderer.citationTime("12:90") == nil)
        #expect(MarkdownReadingRenderer.citationTime("bad:01:02") == nil)
        #expect(MarkdownReadingRenderer.citationTime("999999999999999999999:01") == nil)
        let text = MarkdownReadingRenderer.inline(
            "See [12:39][15:28] and 【81:32–82:00】.", font: .systemFont(ofSize: 14))
        #expect(text.string == "See 12:39 15:28 and 81:32.")
        var links: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
        }
        #expect(links == ["gday-time://759", "gday-time://928", "gday-time://4892"])
    }
    @Test func checkboxPreservesOtherTasksAndTiming() {
        let source = "- [ ] First <!-- gday:t=0:12 -->\n- [x] Second"
        let taskLine = NotesReadingDocument(source).blocks.first!.id
        #expect(NotesDocument(source).time(atLine: taskLine) == 12)
        let updated = MarkdownReadingRenderer.togglingTask(in: source, line: taskLine)
        #expect(updated.contains("- [x] First"))
        #expect(updated.contains("- [x] Second"))
        #expect(NotesDocument(updated).time(atLine: taskLine) == 12)
        #expect(updated == "- [x] First <!-- gday:t=0:12 -->\n- [x] Second")
        #expect(MarkdownReadingRenderer.togglingTask(in: "1. [ ] Numbered", line: 0).contains("1. [x] Numbered"))
    }
    @Test func oneDocumentContainsAllSelectableParagraphs() {
        let text = MarkdownReadingRenderer.render(
            "# Title\n\nParagraph one.\n\n- [ ] Task [00:12]\n\nParagraph two.",
            timestamps: false, emptyMessage: "Empty", directory: URL(fileURLWithPath: "/tmp"), interactiveTasks: true)
        #expect(text.string.contains("Title\nParagraph one.\n\u{fffc}\tTask 00:12\nParagraph two."))
        let range = (text.string as NSString).range(of: "\u{fffc}")
        #expect(text.attribute(.markdownTaskLine, at: range.location, effectiveRange: nil) as? Int == 4)
    }
    @Test func summaryPreviewDoesNotReserveBlankLines() {
        #expect(MeetingSummaryPreview.text("  Title  \n\n  \n") == "Title")
        #expect(MeetingSummaryPreview.rowHeight("Title\n\n", width: 300) < 76)
        #expect(MeetingSummaryPreview.rowHeight(" \n ", width: 300) == 48)
        #expect(MeetingSummaryPreview.text("Title\n\nBody") == "Title\nBody")
    }
    @Test func wrappedTaskTargetsRespectLinksAndTextSelection() {
        let row = MarkdownReadingTextView.TaskRegion(
            line: 3, checked: false,
            frame: NSRect(x: 10, y: 20, width: 400, height: 80), marker: NSRect(x: 15, y: 23, width: 14, height: 14))
        let point = NSPoint(x: 250, y: 85)
        #expect(MarkdownReadingTextView.taskTarget(at: point, regions: [row], hasLink: false, clickCount: 1)?.line == 3)
        #expect(MarkdownReadingTextView.taskTarget(at: point, regions: [row], hasLink: true, clickCount: 1) == nil)
        #expect(MarkdownReadingTextView.taskTarget(at: point, regions: [row], hasLink: false, clickCount: 2) == nil)
        #expect(
            MarkdownReadingTextView.taskTarget(
                at: NSPoint(x: 250, y: 110), regions: [row], hasLink: false, clickCount: 1) == nil)
        let text = MarkdownReadingRenderer.render(
            "- [ ] A long task with a citation [00:06]", timestamps: false,
            emptyMessage: "Empty", directory: URL(fileURLWithPath: "/tmp"), interactiveTasks: true)
        let citation = (text.string as NSString).range(of: "00:06")
        #expect(text.attribute(.markdownTaskLine, at: citation.location, effectiveRange: nil) as? Int == 0)
        #expect((text.attribute(.link, at: citation.location, effectiveRange: nil) as? URL)?.scheme == "gday-time")
    }

    @Test func taskGeometryWorksAfterNativeTable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let text = MarkdownReadingTextView(usingTextLayoutManager: true)
        text.frame = scroll.bounds
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.drawsBackground = false
        scroll.documentView = text
        window.contentView = scroll
        text.textStorage?.setAttributedString(
            MarkdownReadingRenderer.render(
                "| Topic | Decision |\n| --- | --- |\n| Release | Friday |\n\n- [ ] "
                    + String(repeating: "Review the schedule and check the release date. ", count: 5)
                    + "\n- [x] Send notes.",
                timestamps: false, emptyMessage: "Empty", directory: URL(fileURLWithPath: "/tmp"),
                interactiveTasks: true))
        window.contentView?.layoutSubtreeIfNeeded()
        text.layoutSubtreeIfNeeded()
        text.refreshTaskRanges()
        let regions = text.taskRegions()
        let plain = text.string as NSString
        let checkedIndex = plain.range(of: "Send notes.").location
        let screen = text.firstRect(forCharacterRange: NSRange(location: checkedIndex, length: 1), actualRange: nil)
        let line = text.convert(window.convertFromScreen(screen), from: nil)
        let font = NSFont.systemFont(ofSize: 14)
        let baseline = line.maxY + font.descender
        let visualTop = baseline - font.ascender
        let visualBottom = baseline - font.descender
        if let single = regions.last {
            // Compare with actual input line bounds, independently of layout-fragment lookup.
            #expect(abs(single.marker.midY - (visualTop + visualBottom) / 2) < 1)
            #expect(single.marker.midY > line.minY && single.marker.midY < line.maxY)
            #expect(abs((visualTop - single.frame.minY) - (single.frame.maxY - visualBottom)) < 2)
            #expect(single.frame.minY > line.minY)
        }
        window.setContentSize(NSSize(width: 500, height: 160))
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let scrolled = text.taskRegions()
        #expect(scrolled.count == 2)
        if scrolled.count == 2 {
            #expect(scrolled[1].marker.minY > scrolled[0].marker.maxY + 40)
            #expect(abs(scrolled[1].marker.midY - regions[1].marker.midY) < 0.1)
            let actualScreen = text.firstRect(
                forCharacterRange: NSRange(location: checkedIndex, length: 1), actualRange: nil)
            let actualLine = text.convert(window.convertFromScreen(actualScreen), from: nil)
            #expect(scrolled[1].marker.midY > actualLine.minY && scrolled[1].marker.midY < actualLine.maxY)
        }
        #expect(regions.count == 2)
        #expect(regions.map(\.checked) == [false, true])
        #expect(regions.allSatisfy { $0.marker.size == NSSize(width: 14, height: 14) })
        #expect(regions.allSatisfy { $0.frame.width > $0.marker.width })
        if let wrapped = regions.first {
            #expect(wrapped.frame.height > 30)
            let point = NSPoint(x: wrapped.frame.midX, y: wrapped.frame.maxY - 2)
            #expect(
                MarkdownReadingTextView.taskTarget(at: point, regions: regions, hasLink: false, clickCount: 1)?.line
                    == wrapped.line)
        }
    }

    @Test func renderedSelectionCopiesMarkdownSource() {
        let source =
            "# **Heading**\n\n- First **release plan** [guide](https://example.com) [12:39][15:28]\n- [x] Second item\n\n| Topic | Decision |\n| --- | --- |\n| Release | Friday |"
        let rendered = MarkdownReadingRenderer.render(
            source, timestamps: false, emptyMessage: "", directory: URL(fileURLWithPath: "/tmp"), interactiveTasks: true
        )
        let plain = rendered.string as NSString
        let plan = plain.range(of: "plan")
        #expect(MarkdownReadingSelectionCopy.markdown(from: rendered, selection: plan) == "- **plan**")
        let citation = plain.range(of: "12:39")
        #expect(MarkdownReadingSelectionCopy.markdown(from: rendered, selection: citation) == "- [12:39]")
        let second = plain.range(of: "Second item")
        let mixed = NSRange(location: plan.location, length: NSMaxRange(second) - plan.location)
        let copied = MarkdownReadingSelectionCopy.markdown(from: rendered, selection: mixed)
        #expect(copied.contains("**plan** [guide](<https://example.com>) [12:39][15:28]"))
        #expect(copied.contains("- [x] Second item"))
        #expect(!copied.contains("First"))
        let friday = plain.range(of: "Friday")
        let tableCopy = MarkdownReadingSelectionCopy.markdown(from: rendered, selection: friday)
        #expect(tableCopy.contains("Friday"))
        #expect(tableCopy.contains("---"))
        #expect(!tableCopy.contains("Release"))
        #expect(!tableCopy.contains("Decision"))
    }

    @Test func previewTasksAreNativeInlineAttachments() {
        let source = """
            ### Key points

            - Review the **release plan** with the team. [00:06][00:11]
            - Keep the meeting notes up to date.

            ### Decisions

            | Topic | Decision |
            | --- | --- |
            | Release | Start with the Mac app |
            | Review | Meet on Friday |

            ### Action items

            - [ ] Alex: Update the schedule.
            - [x] Sam: Check the meeting notes.
            """
        let rendered = MarkdownReadingRenderer.render(
            source, timestamps: false, emptyMessage: "", directory: URL(fileURLWithPath: "/tmp"), interactiveTasks: true
        )
        let string = rendered.string as NSString
        for name in ["Alex:", "Sam:"] {
            let start = string.range(of: name).location - 2
            let attachment = rendered.attribute(.attachment, at: start, effectiveRange: nil) as? NSTextAttachment
            #expect(attachment?.bounds == NSRect(x: 0, y: -2, width: 14, height: 14))
            #expect(string.substring(with: NSRange(location: start, length: 1)) == "\u{fffc}")
        }
        let copied = MarkdownReadingSelectionCopy.markdown(
            from: rendered, selection: NSRange(location: 0, length: rendered.length))
        #expect(copied.contains("- [ ] Alex: Update the schedule."))
        #expect(copied.contains("- [x] Sam: Check the meeting notes."))
    }

}
