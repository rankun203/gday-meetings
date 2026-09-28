import Foundation
import Testing

@testable import GdayMeetings

struct MarkdownReadingSelectionCopyTests {
    @Test func generatedMarkerAndTrailingNewlineDoNotCopyStrayPrefixes() {
        let text = block("Task text", prefix: "- [ ] ", decoration: "☐\t")
        #expect(MarkdownReadingSelectionCopy.markdown(from: text, selection: NSRange(location: 0, length: 2)).isEmpty)
        #expect(
            MarkdownReadingSelectionCopy.markdown(from: text, selection: NSRange(location: text.length - 1, length: 1))
                .isEmpty)
    }
    @Test func imageAndDividerSelectionsPreserveOriginalSource() {
        for (display, source) in [("Diagram", "![Diagram](assets/diagram.png)"), ("────────", "---")] {
            let text = NSMutableAttributedString(string: display + "\n")
            text.addAttribute(
                .markdownCopyBlock, value: MarkdownCopyBlock(source: source, kind: .atomic),
                range: NSRange(location: 0, length: text.length))
            #expect(
                MarkdownReadingSelectionCopy.markdown(from: text, selection: NSRange(location: 1, length: 1)) == source)
        }
    }
    private func block(_ source: String, prefix: String = "", decoration: String = "") -> NSAttributedString {
        let context = MarkdownInlineCopyContext(source: source)
        let text = NSMutableAttributedString(string: decoration + context.map.rendered + "\n")
        text.addAttribute(
            .markdownCopyBlock, value: MarkdownCopyBlock(source: prefix + source, kind: .text(prefix: prefix)),
            range: NSRange(location: 0, length: text.length))
        text.addAttribute(
            .markdownInlineCopy, value: context,
            range: NSRange(location: (decoration as NSString).length, length: (context.map.rendered as NSString).length)
        )
        return text
    }
    @Test func partialHeadingAndCheckedTaskPreserveStructuralSyntax() {
        let heading = block("Some **heading** here", prefix: "## ")
        #expect(
            MarkdownReadingSelectionCopy.markdown(
                from: heading, selection: (heading.string as NSString).range(of: "heading")) == "## **heading**")
        let task = block("Finish **this** today", prefix: "- [x] ", decoration: "☑\t")
        #expect(
            MarkdownReadingSelectionCopy.markdown(from: task, selection: (task.string as NSString).range(of: "this"))
                == "- [x] **this**")
    }
    @Test func selectionAcrossBlocksDoesNotIncludeUnselectedText() {
        let text = NSMutableAttributedString(attributedString: block("Keep first", prefix: "- ", decoration: "•\t"))
        text.append(block("Keep second", prefix: "- ", decoration: "•\t"))
        text.append(block("Unselected secret"))
        let range = (text.string as NSString).range(of: "second")
        let copied = MarkdownReadingSelectionCopy.markdown(
            from: text, selection: NSRange(location: 0, length: NSMaxRange(range)))
        #expect(copied == "- Keep first\n- Keep second")
        #expect(!copied.contains("secret"))
    }
    @Test func partialTableCopiesOnlySelectedCellAndValidStructure() {
        let text = NSMutableAttributedString(string: "Name\nRole\nAlex\nEngineer\nSam\nDesigner\n")
        let cells = ["Name", "Role", "Alex", "Engineer", "Sam", "Designer"]
        var offset = 0
        let mapped = cells.enumerated().map { index, cell in
            let range = NSRange(location: offset, length: (cell as NSString).length)
            offset += range.length + 1
            return MarkdownCopyBlock.Cell(
                range: range, row: index / 2, column: index % 2, context: MarkdownInlineCopyContext(source: cell))
        }
        text.addAttribute(
            .markdownCopyBlock,
            value: MarkdownCopyBlock(
                source: "| Name | Role |\n| --- | --- |\n| Alex | Engineer |\n| Sam | Designer |", kind: .table,
                cells: mapped), range: NSRange(location: 0, length: text.length))
        let copied = MarkdownReadingSelectionCopy.markdown(
            from: text, selection: (text.string as NSString).range(of: "Engineer"))
        #expect(copied == "|  |\n| --- |\n| Engineer |")
        #expect(!copied.contains("Alex"))
        #expect(!copied.contains("Role"))
    }
    @Test func codeSelectionUsesNoncollidingFence() {
        let text = NSMutableAttributedString(string: "before\na```b\nafter\n")
        text.addAttribute(
            .markdownCopyBlock, value: MarkdownCopyBlock(source: "unused", kind: .code(language: "swift")),
            range: NSRange(location: 0, length: text.length))
        #expect(
            MarkdownReadingSelectionCopy.markdown(from: text, selection: (text.string as NSString).range(of: "a```b"))
                == "````swift\na```b\n````")
    }
}
