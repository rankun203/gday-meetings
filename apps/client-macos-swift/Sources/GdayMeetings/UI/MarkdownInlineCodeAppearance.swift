import AppKit

/// Decorations never insert characters, so text selection and source positions
/// retain the same offsets as the Markdown parser and citation replacements.
enum MarkdownInlineCodeAppearance {
    static let horizontalPadding: CGFloat = 3

    static func applyPadding(to text: NSMutableAttributedString) {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            if value as? Bool == true, range.length > 0 { ranges.append(range) }
        }
        let string = text.string as NSString
        for range in ranges {
            var boundaries = [string.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)]
            if range.location > 0 {
                let before = string.rangeOfComposedCharacterSequence(at: range.location - 1)
                if !string.substring(with: before).contains(where: \.isNewline) { boundaries.append(before) }
            }
            for boundary in boundaries {
                let existing =
                    (text.attribute(.kern, at: boundary.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                text.addAttribute(.kern, value: existing + Double(horizontalPadding), range: boundary)
            }
        }
    }

    static func backgroundFrame(for textFrame: NSRect, last: Bool) -> NSRect {
        var frame = textFrame
        // The last text segment already includes the final glyph's trailing
        // kern. Count that space once when padding the background.
        if last { frame.size.width = max(0, frame.width - horizontalPadding) }
        return frame.insetBy(dx: -horizontalPadding, dy: -1)
    }
}

extension MarkdownReadingTextView {
    func drawInlineCodeBackgrounds(in dirtyRect: NSRect) {
        let viewport: NSRange?
        if let manager = textLayoutManager, let content = manager.textContentManager,
            let range = manager.textViewportLayoutController.viewportRange
        {
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let length = content.offset(from: range.location, to: range.endLocation)
            viewport = NSRange(location: start, length: length)
        }
        else {
            viewport = nil
        }
        for range in inlineCodeRanges {
            if let viewport, NSIntersectionRange(range, viewport).length == 0 { continue }
            let frames = textRangeRects(range, glyphBounds: true)
            for (index, textFrame) in frames.enumerated() {
                let frame = MarkdownInlineCodeAppearance.backgroundFrame(
                    for: textFrame, last: index == frames.count - 1)
                guard frame.intersects(dirtyRect) else { continue }
                NSColor.labelColor.withAlphaComponent(0.075).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

extension NSAttributedString.Key {
    static let markdownInlineCode = NSAttributedString.Key("GdayMarkdownInlineCode")
}
