import AppKit
import ImageIO
import SwiftUI

/// One selectable document, rather than separately selectable SwiftUI paragraphs.
struct NativeMarkdownReadingView: NSViewRepresentable {
    let markdown: String
    let showsTimestamps: Bool
    let emptyMessage: String
    let directory: URL
    var changed: ((String) -> Void)?
    var play: (TimeInterval) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let text = MarkdownReadingTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.delegate = text
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        text.setAccessibilityLabel("Markdown document")
        scroll.documentView = text
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? MarkdownReadingTextView else { return }
        text.configuration = self
        // Scrolling and unrelated store/player changes never parse or relayout the document.
        guard
            text.source != markdown || text.timestamps != showsTimestamps
                || text.emptyMessage != emptyMessage || text.interactiveTasks != (changed != nil)
                || text.directory != directory
        else { return }
        text.source = markdown
        text.timestamps = showsTimestamps
        text.emptyMessage = emptyMessage
        text.interactiveTasks = changed != nil
        text.directory = directory
        let position = scroll.contentView.bounds.origin
        let selection = text.selectedRange()
        text.textStorage?.setAttributedString(
            MarkdownReadingRenderer.render(
                markdown, timestamps: showsTimestamps, emptyMessage: emptyMessage, directory: directory,
                interactiveTasks: changed != nil))
        text.refreshTaskRanges()
        text.setSelectedRange(NSRange(location: min(selection.location, text.string.utf16.count), length: 0))
        scroll.contentView.scroll(to: position)
    }
}

final class MarkdownReadingTextView: NSTextView, NSTextViewDelegate {
    var configuration: NativeMarkdownReadingView?
    var source: String?
    var timestamps = false
    var emptyMessage = ""
    var interactiveTasks = false
    var directory: URL?
    private var hoverLine: Int?
    private var tracking: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    struct TaskRegion {
        let line: Int
        let checked: Bool
        let frame: NSRect
        let marker: NSRect
    }
    static func taskTarget(at point: NSPoint, regions: [TaskRegion], hasLink: Bool, clickCount: Int) -> TaskRegion? {
        guard !hasLink, clickCount == 1 else { return nil }
        return regions.first { $0.frame.contains(point) }
    }
    private var taskRanges: [(line: Int, checked: Bool, range: NSRange)] = []
    func refreshTaskRanges() {
        taskRanges.removeAll(keepingCapacity: true)
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.markdownTaskLine, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let line = value as? Int else { return }
            self.taskRanges.append(
                (
                    line,
                    storage.attribute(.markdownTaskChecked, at: range.location, effectiveRange: nil) as? Bool ?? false,
                    range
                ))
        }
    }
    func taskRegions() -> [TaskRegion] {
        guard let window, !taskRanges.isEmpty else { return [] }
        let visible = visibleRect
        func rect(_ index: Int) -> NSRect {
            let screen = firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            return convert(window.convertFromScreen(screen), from: nil)
        }
        // Native input geometry works with either layout engine. Binary search
        // cached paragraph ranges rather than hit-testing text-container margins:
        // AppKit maps clicks in those margins to the end of the document.
        var low = 0
        var high = taskRanges.count
        while low < high {
            let middle = (low + high) / 2
            if rect(NSMaxRange(taskRanges[middle].range) - 1).maxY < visible.minY {
                low = middle + 1
            }
            else {
                high = middle
            }
        }
        var result: [TaskRegion] = []
        for task in taskRanges.dropFirst(low) {
            let leading = rect(task.range.location)
            if leading.minY > visible.maxY { break }
            let trailing = rect(NSMaxRange(task.range) - 1)
            func glyphBounds(_ index: Int, line: NSRect) -> NSRect {
                let font =
                    textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                    ?? NSFont.systemFont(ofSize: 14)
                let baseline = line.maxY + font.descender
                return NSRect(
                    x: line.minX, y: baseline - font.ascender,
                    width: line.width, height: font.ascender - font.descender)
            }
            let bodyStart = min(task.range.location + 2, NSMaxRange(task.range) - 1)
            let firstGlyph = glyphBounds(bodyStart, line: rect(bodyStart))
            let lastGlyph = glyphBounds(NSMaxRange(task.range) - 1, line: trailing)
            let frame = firstGlyph.union(lastGlyph).insetBy(dx: 0, dy: -3)
            guard frame.intersects(visible) else { continue }
            result.append(
                TaskRegion(
                    line: task.line, checked: task.checked,
                    frame: NSRect(
                        x: textContainerOrigin.x - 5, y: frame.minY,
                        width: max(0, bounds.width - textContainerOrigin.x * 2 + 10), height: max(20, frame.height)),
                    marker: NSRect(
                        x: leading.minX, y: firstGlyph.midY - 7, width: 14, height: 14)))
        }
        return result
    }
    override func copy(_ sender: Any?) {
        guard let textStorage else { return }
        let markdown = MarkdownReadingSelectionCopy.markdown(from: textStorage, selection: selectedRange())
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
    override func draw(_ dirtyRect: NSRect) {
        let regions = taskRegions()
        if let hovered = regions.first(where: { $0.line == hoverLine }) {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: hovered.frame, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if window != nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHovered(nil) }
            }
        }
    }
    private func setHovered(_ line: Int?) {
        guard hoverLine != line else { return }
        hoverLine = line
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = taskRegions().first { $0.frame.contains(point) }
        setHovered(row?.line)
        if row != nil {
            NSCursor.pointingHand.set()
        }
        else {
            super.mouseMoved(with: event)
        }
    }
    override func cursorUpdate(with event: NSEvent) {
        if taskRegions().contains(where: { $0.frame.contains(convert(event.locationInWindow, from: nil)) }) {
            NSCursor.pointingHand.set()
        }
        else {
            super.cursorUpdate(with: event)
        }
    }
    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        super.mouseExited(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let linked =
            index < (textStorage?.length ?? 0) && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        guard configuration?.changed != nil,
            event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
            let row = Self.taskTarget(at: point, regions: taskRegions(), hasLink: linked, clickCount: event.clickCount),
            let next = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
                dequeue: false), next.type == .leftMouseUp
        else {
            super.mouseDown(with: event)
            return
        }
        _ = window?.nextEvent(matching: .leftMouseUp)
        if let source { configuration?.changed?(MarkdownReadingRenderer.togglingTask(in: source, line: row.line)) }
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard configuration?.changed != nil else { return super.accessibilityCustomActions() }
        return taskRegions().map { row in
            NSAccessibilityCustomAction(name: row.checked ? "Mark to-do incomplete" : "Mark to-do complete") {
                [weak self] in
                guard let self, let source = self.source else { return false }
                self.configuration?.changed?(MarkdownReadingRenderer.togglingTask(in: source, line: row.line))
                return true
            }
        }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if url.scheme == "gday-time", let time = Double(url.host ?? ""), time.isFinite, time >= 0 {
            configuration?.play(time)
        }
        else if url.scheme == "gday-task", let line = Int(url.host ?? ""), let source {
            configuration?.changed?(MarkdownReadingRenderer.togglingTask(in: source, line: line))
        }
        else if url.scheme == "gday-image", let configuration,
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                $0.name == "path"
            })?.value,
            let image = try? NotesAssets.safeURL(relativePath: path, directory: configuration.directory)
        {
            NSWorkspace.shared.open(image)
        }
        else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

@MainActor enum MarkdownReadingRenderer {
    static func togglingTask(in source: String, line: Int) -> String {
        var document = NotesDocument(source)
        guard document.lines.indices.contains(line) else { return source }
        let text = document.lines[line].text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+\.)\s+\[([ xX])\]"#),
            let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length))
        else { return source }
        let range = match.range(at: 1)
        let replacement = text.substring(with: range) == " " ? "x" : " "
        let global = NSRange(location: document.range(of: line).location + range.location, length: range.length)
        document.replace(global, with: replacement, clock: nil, phraseClock: nil)
        return document.markdown
    }

    static func citationTime(_ value: String) -> TimeInterval? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        let parts = components.compactMap { Double($0) }
        guard parts.count == components.count, (2...3).contains(parts.count),
            parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
            parts.last! < 60, parts.count == 2 || parts[1] < 60
        else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total.isFinite && total <= Double(Int.max / 2) ? total : nil
    }

    private static func taskImage(checked: Bool) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: true) { bounds in
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.5, yRadius: 2.5)
            if checked {
                NSColor.controlAccentColor.setFill()
                box.fill()
                NSColor.white.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.move(to: NSPoint(x: 3, y: 7))
                check.line(to: NSPoint(x: 6, y: 10))
                check.line(to: NSPoint(x: 11, y: 4))
                check.stroke()
            }
            else {
                NSColor.secondaryLabelColor.setStroke()
                box.lineWidth = 1.2
                box.stroke()
            }
            return true
        }
    }

    static func inline(_ source: String, font: NSFont) -> NSMutableAttributedString {
        let copyContext = MarkdownInlineCopyContext(source: source)
        let parsed = copyContext.map.parsed
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes(
            [.font: font, .foregroundColor: NSColor.labelColor, .markdownInlineCopy: copyContext], range: full)
        // Foundation carries inline intent; apply the native font traits explicitly.
        var offset = 0
        var codeRanges: [NSRange] = []
        for run in parsed.runs {
            let length = String(parsed[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            var styled = font
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask)
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                codeRanges.append(range)
                styled = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                result.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            }
            result.addAttribute(.font, value: styled, range: range)
            offset += length
        }
        let pattern = #"[\[【](\d+(?::\d{2}){1,2})(?:\s*[-–—‑]\s*\d+(?::\d{2}){1,2})?[\]】]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let string = result.string as NSString
            // Compute labels and adjacency before any replacements: NSTextStorage
            // can expose an NSString view backed by its changing characters.
            let citations = regex.matches(in: result.string, range: full).compactMap {
                match -> (NSRange, String, URL, Bool)? in
                guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                    result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                    let time = citationTime(string.substring(with: match.range(at: 1))),
                    let url = URL(string: "gday-time://\(Int(time))")
                else { return nil }
                let adjacent =
                    NSMaxRange(match.range) < string.length
                    && ["[", "【"].contains(
                        string.substring(with: NSRange(location: NSMaxRange(match.range), length: 1)))
                return (match.range, string.substring(with: match.range(at: 1)), url, adjacent)
            }
            copyContext.edits = citations.map { range, label, _, adjacent in
                .init(original: range, replacementLength: label.utf16.count + (adjacent ? 1 : 0))
            }
            for (range, label, url, adjacent) in citations.reversed() {
                var attributes = result.attributes(at: range.location, effectiveRange: nil)
                attributes[.link] = url
                let replacement = NSMutableAttributedString(string: label, attributes: attributes)
                if adjacent {
                    replacement.append(
                        NSAttributedString(string: " ", attributes: [.font: font, .markdownInlineCopy: copyContext]))
                }
                result.replaceCharacters(in: range, with: replacement)
            }
        }
        return result
    }

    static func render(
        _ source: String, timestamps: Bool, emptyMessage: String, directory: URL,
        interactiveTasks: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let blocks = NotesReadingDocument(source).blocks
        let sourceLines = NotesDocument(source).lines.map(\.text)
        for (blockIndex, block) in blocks.enumerated() {
            let endLine = blockIndex + 1 < blocks.count ? blocks[blockIndex + 1].id : sourceLines.count
            var blockLines = Array(sourceLines[block.id..<endLine])
            while blockLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                blockLines.removeLast()
            }
            let blockSource = blockLines.joined(separator: "\n")
            var copyKind = MarkdownCopyBlock.Kind.text(prefix: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.35
            paragraph.paragraphSpacing = 10
            var value: NSMutableAttributedString
            switch block.content {
            case .text(let text), .literal(let text): value = inline(text, font: bodyFont)
            case .heading(let text, let level):
                copyKind = .text(prefix: String(repeating: "#", count: level) + " ")
                value = inline(
                    text, font: .systemFont(ofSize: level == 1 ? 26 : (level == 2 ? 21 : 17), weight: .semibold))
                paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 14
                paragraph.paragraphSpacing = 10
            case .list(let text, let bullet):
                let prefixRange = blockSource.range(
                    of: #"^\s*(?:[-+*]|\d+\.)\s+(?:\[[ xX]\]\s*)?"#, options: .regularExpression)
                copyKind = .text(prefix: prefixRange.map { String(blockSource[$0]) } ?? "- ")
                value = inline(text, font: bodyFont)
                value.insert(NSAttributedString(string: bullet + "\t", attributes: [.font: bodyFont]), at: 0)
                let listIndent: CGFloat = bullet == "•" ? 18 : 22
                if bullet == "•" {
                    value.addAttribute(
                        .font, value: NSFont.systemFont(ofSize: bodyFont.pointSize + 1),
                        range: NSRange(location: 0, length: 1))
                }
                paragraph.headIndent = listIndent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
                paragraph.paragraphSpacing = 4
                if interactiveTasks && ["☐", "☑"].contains(bullet) {
                    let attachment = NSTextAttachment()
                    attachment.image = taskImage(checked: bullet == "☑")
                    attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
                    value.replaceCharacters(
                        in: NSRange(location: 0, length: 1), with: NSAttributedString(attachment: attachment))
                    value.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: 1))
                    value.addAttributes(
                        [.markdownTaskLine: block.id, .markdownTaskChecked: bullet == "☑"],
                        range: NSRange(location: 0, length: value.length))
                }
                if bullet == "☑" {
                    value.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                        range: NSRange(location: 2, length: max(0, value.length - 2)))
                }
            case .quote(let text):
                copyKind = .text(prefix: "> ")
                value = inline(text, font: bodyFont)
                value.insert(NSAttributedString(string: "│  ", attributes: [.font: bodyFont]), at: 0)
                value.addAttribute(
                    .foregroundColor, value: NSColor.secondaryLabelColor,
                    range: NSRange(location: 0, length: value.length))
                paragraph.headIndent = 18
            case .code(let text):
                let firstLine = blockLines.first ?? "```"
                let language = String(firstLine.drop(while: { $0 == "`" || $0 == "~" || $0.isWhitespace }))
                copyKind = .code(language: language)
                value = NSMutableAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor,
                    ])
            case .divider:
                copyKind = .atomic
                value = NSMutableAttributedString(
                    string: "────────────────────────",
                    attributes: [
                        .foregroundColor: NSColor.separatorColor, .font: bodyFont,
                    ])
            case .table(let rows, let alignments):
                let tableStart = result.length
                var copyCells: [MarkdownCopyBlock.Cell] = []
                let table = NSTextTable()
                table.numberOfColumns = alignments.count
                table.collapsesBorders = true
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                for (rowIndex, row) in rows.enumerated() {
                    for (column, cell) in row.enumerated() {
                        let block = NSTextTableBlock(
                            table: table, startingRow: rowIndex, rowSpan: 1,
                            startingColumn: column, columnSpan: 1)
                        block.setWidth(6, type: .absoluteValueType, for: .padding)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(.separatorColor)
                        block.setValue(100 / CGFloat(max(1, alignments.count)), type: .percentageValueType, for: .width)
                        if rowIndex == 0 { block.backgroundColor = .quaternaryLabelColor }
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = [block]
                        style.lineHeightMultiple = 1.35
                        style.alignment =
                            alignments[column] == .trailing ? .right : (alignments[column] == .center ? .center : .left)
                        let cellText = inline(cell, font: rowIndex == 0 ? .boldSystemFont(ofSize: 14) : bodyFont)
                        let context =
                            cellText.length > 0
                            ? cellText.attribute(.markdownInlineCopy, at: 0, effectiveRange: nil)
                                as? MarkdownInlineCopyContext : nil
                        copyCells.append(
                            .init(
                                range: NSRange(location: result.length - tableStart, length: cellText.length),
                                row: rowIndex, column: column,
                                context: context ?? MarkdownInlineCopyContext(source: cell)))
                        cellText.append(NSAttributedString(string: "\n"))
                        cellText.addAttribute(
                            .paragraphStyle, value: style, range: NSRange(location: 0, length: cellText.length))
                        result.append(cellText)
                    }
                }
                result.addAttribute(
                    .markdownCopyBlock, value: MarkdownCopyBlock(source: blockSource, kind: .table, cells: copyCells),
                    range: NSRange(location: tableStart, length: result.length - tableStart))
                continue
            case .image(let reference):
                copyKind = .atomic
                if let url = try? NotesAssets.safeURL(relativePath: reference.displayPath, directory: directory),
                    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let bitmap = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1200,
                        ] as CFDictionary)
                {
                    let image = NSImage(cgImage: bitmap, size: .zero)
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let width = min(CGFloat(reference.width ?? 480), image.size.width)
                    attachment.bounds = NSRect(
                        x: 0, y: 0, width: width, height: width * image.size.height / max(1, image.size.width))
                    value = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    var link = URLComponents()
                    link.scheme = "gday-image"
                    link.host = "original"
                    link.queryItems = [URLQueryItem(name: "path", value: reference.originalPath)]
                    if let url = link.url {
                        value.addAttribute(.link, value: url, range: NSRange(location: 0, length: value.length))
                    }
                }
                else {
                    value = inline(reference.alt.isEmpty ? "Image unavailable" : reference.alt, font: bodyFont)
                }
            }
            if timestamps, let time = block.time {
                let prefix = NSMutableAttributedString(
                    string: NotesDocument.timestamp(time) + "  ",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                        .link: URL(string: "gday-time://\(Int(time))")!,
                    ])
                value.insert(prefix, at: 0)
            }
            value.append(NSAttributedString(string: "\n"))
            value.addAttribute(
                .markdownCopyBlock, value: MarkdownCopyBlock(source: blockSource, kind: copyKind),
                range: NSRange(location: 0, length: value.length))
            value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
            result.append(value)
        }
        if result.length == 0 {
            result.append(
                NSAttributedString(
                    string: emptyMessage,
                    attributes: [
                        .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        return result
    }
}

extension NSAttributedString.Key {
    static let markdownTaskLine = NSAttributedString.Key("GdayMarkdownTaskLine")
    static let markdownTaskChecked = NSAttributedString.Key("GdayMarkdownTaskChecked")
}
