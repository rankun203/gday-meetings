import Foundation
import Testing

@testable import GdayMeetings

struct MarkdownSelectionSourceMapTests {
    @Test func entireSelectionPreservesExactSource() {
        let source = "**Bold** _emphasis_ [link](https://example.com \"Title\") &amp; \\*"
        let map = MarkdownSelectionSourceMap(source: source)
        #expect(map.markdown(in: NSRange(location: 0, length: (map.rendered as NSString).length)) == source)
    }
    @Test func partialFormattingAndLinkRemainBalanced() throws {
        let map = MarkdownSelectionSourceMap(source: "Start **bold and _italic_** [label](https://example.com) end")
        let text = map.rendered as NSString
        let partial = map.markdown(in: text.range(of: "and italic"))
        let reparsed = try AttributedString(
            markdown: partial, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(reparsed.characters) == "and italic")
        #expect(reparsed.runs.filter { $0.inlinePresentationIntent != nil }.count > 0)
        let link = map.markdown(in: NSRange(location: text.range(of: "label").location + 1, length: 3))
        let parsedLink = try AttributedString(
            markdown: link, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(parsedLink.characters) == "abe")
        #expect(parsedLink.runs.first?.link?.absoluteString == "https://example.com")
    }
    @Test func repeatedPhrasesUseTheirOwnSourcePosition() {
        let map = MarkdownSelectionSourceMap(source: "**repeat** then _repeat_")
        let second = (map.rendered as NSString).range(of: "repeat", options: .backwards)
        #expect(map.markdown(in: second) == "*repeat*")
    }
    @Test func decodedEntitiesAndEscapesRetainSourceTokens() {
        let map = MarkdownSelectionSourceMap(source: "A &amp; B \\* C")
        let text = map.rendered as NSString
        #expect(map.markdown(in: text.range(of: "&")) == "&amp;")
        #expect(map.markdown(in: text.range(of: "*")) == "\\*")
    }
    @Test func selectionDoesNotSplitComposedUnicode() {
        let map = MarkdownSelectionSourceMap(source: "before **👩🏽‍💻 café** after")
        let location = (map.rendered as NSString).range(of: "👩🏽‍💻").location
        #expect(map.markdown(in: NSRange(location: location + 1, length: 1)) == "**👩🏽‍💻**")
    }
    @Test func partialCodeFenceCannotCollideWithBackticks() throws {
        let map = MarkdownSelectionSourceMap(source: "before ``a`b`` after")
        let copied = map.markdown(in: (map.rendered as NSString).range(of: "a`"))
        let parsed = try AttributedString(
            markdown: copied, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(parsed.characters) == "a`")
        #expect(parsed.runs.first?.inlinePresentationIntent?.contains(.code) == true)
    }
    @Test func transformedCitationsAreAtomicAndLaterOffsetsStayCorrect() {
        let source = "A [12:34] and [1:02:03] end"
        let context = MarkdownInlineCopyContext(source: source)
        let original = context.map.rendered as NSString
        context.edits = [
            .init(original: original.range(of: "[12:34]"), replacementLength: 5),
            .init(original: original.range(of: "[1:02:03]"), replacementLength: 7),
        ]
        let rendered = "A 12:34 and 1:02:03 end" as NSString
        #expect(
            context.markdown(in: NSRange(location: rendered.range(of: "12:34").location + 1, length: 2)) == "[12:34]")
        #expect(context.markdown(in: rendered.range(of: "1:02:03")) == "[1:02:03]")
        #expect(context.markdown(in: rendered.range(of: "end")) == "end")
        #expect(context.markdown(in: NSRange(location: 0, length: rendered.length)) == source)
    }
}
