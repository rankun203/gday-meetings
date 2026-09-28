import Foundation

/// Maps selection offsets to parser-provided source positions, never by searching
/// for selected words. Repeated phrases therefore retain their own source identity.
struct MarkdownSelectionSourceMap {
    let source: String
    let parsed: AttributedString
    let rendered: String

    init(source: String) {
        self.source = source
        parsed =
            (try? AttributedString(
                markdown: source,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)))
            ?? AttributedString(source)
        rendered = String(parsed.characters)
    }

    func markdown(in selection: NSRange) -> String {
        let text = rendered as NSString
        guard selection.location != NSNotFound, selection.length > 0, selection.location < text.length else {
            return ""
        }
        let clipped = NSIntersectionRange(selection, NSRange(location: 0, length: text.length))
        let selected = text.rangeOfComposedCharacterSequences(for: clipped)
        if selected.location == 0 && selected.length == text.length { return source }
        var output = ""
        var opened: [Wrapper] = []
        var offset = 0
        func emit(_ value: String, wrappers: [Wrapper]) {
            let common = zip(opened, wrappers).prefix { $0 == $1 }.count
            for wrapper in opened.dropFirst(common).reversed() { output += wrapper.close }
            for wrapper in wrappers.dropFirst(common) { output += wrapper.open }
            output += value
            opened = wrappers
        }
        for run in parsed.runs {
            let displayed = String(parsed[run.range].characters)
            let count = (displayed as NSString).length
            let intersection = NSIntersectionRange(selected, NSRange(location: offset, length: count))
            defer { offset += count }
            guard intersection.length > 0 else { continue }
            let local = NSRange(location: intersection.location - offset, length: intersection.length)
            let visible = (displayed as NSString).substring(with: local)
            let intent = run.inlinePresentationIntent
            let code = intent?.contains(.code) == true
            var raw = Self.escape(visible)
            if let position = run.markdownSourcePosition, let range = Range(position, in: source) {
                let original = String(source[range])
                raw =
                    Self.sourceSlice(original, rendered: displayed, selection: local, code: code)
                    ?? Self.escape(visible)
            }
            var wrappers: [Wrapper] = []
            if let link = run.link { wrappers.append(.link(link.absoluteString)) }
            if code {
                // Code contents are literal. Choose a fence which cannot collide
                // with any selected backtick sequence and preserve edge spaces.
                raw = visible
                let longest =
                    raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(1, longest + 1))
                let needsPadding = raw.first == "`" || raw.last == "`" || raw.first == " " || raw.last == " "
                let padding = needsPadding && !raw.allSatisfy({ $0 == " " }) ? " " : ""
                wrappers.append(.code(fence, padding))
                emit(raw, wrappers: wrappers)
            }
            else {
                if intent?.contains(.stronglyEmphasized) == true { wrappers.append(.strong) }
                if intent?.contains(.emphasized) == true { wrappers.append(.emphasis) }
                if intent?.contains(.strikethrough) == true { wrappers.append(.strike) }
                // Emphasis delimiters cannot flank whitespace. Keep edge spaces
                // outside the formatting without losing their selected content.
                let leading = String(raw.prefix(while: \.isWhitespace))
                let remainder = raw.dropFirst(leading.count)
                let trailing = String(remainder.reversed().prefix(while: \.isWhitespace).reversed())
                let middle = String(remainder.dropLast(trailing.count))
                if !leading.isEmpty { emit(leading, wrappers: []) }
                if !middle.isEmpty { emit(middle, wrappers: wrappers) }
                if !trailing.isEmpty { emit(trailing, wrappers: []) }
            }
        }
        for wrapper in opened.reversed() { output += wrapper.close }
        return output
    }

    private enum Wrapper: Equatable {
        case strong, emphasis, strike
        case code(String, String)
        case link(String)
        var open: String {
            switch self {
            case .strong: "**"
            case .emphasis: "*"
            case .strike: "~~"
            case .code(let fence, let padding): fence + padding
            case .link: "["
            }
        }
        var close: String {
            switch self {
            case .link(let url): "](<" + url.replacingOccurrences(of: ">", with: "%3E") + ">)"
            case .code(let fence, let padding): padding + fence
            default: open
            }
        }
    }

    private static func escape(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>~".contains(character) { result += "\\" }
            result.append(character)
        }
    }

    private static func sourceSlice(_ source: String, rendered: String, selection: NSRange, code: Bool) -> String? {
        if source == rendered { return (source as NSString).substring(with: selection) }
        guard !code else { return nil }
        // Entity/escape expansion is lexical and anchored at the current source
        // offset. It does not match a selected string against surrounding text.
        let input = source as NSString
        var sourceOffset = 0
        var renderedOffset = 0
        var decoded = ""
        var units: [(display: NSRange, source: NSRange)] = []
        while sourceOffset < input.length {
            var sourceRange = input.rangeOfComposedCharacterSequence(at: sourceOffset)
            var value = input.substring(with: sourceRange)
            if value == "\\", NSMaxRange(sourceRange) < input.length {
                let next = input.rangeOfComposedCharacterSequence(at: NSMaxRange(sourceRange))
                let escaped = input.substring(with: next)
                if escaped.unicodeScalars.count == 1, let scalar = escaped.unicodeScalars.first,
                    scalar.isASCII, CharacterSet.punctuationCharacters.union(.symbols).contains(scalar)
                {
                    sourceRange.length += next.length
                    value = escaped
                }
            }
            else if value == "&" {
                let rest = input.substring(from: sourceOffset)
                if let entityRange = rest.range(
                    of: #"^&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#, options: .regularExpression)
                {
                    let entity = String(rest[entityRange])
                    if let parsed = try? AttributedString(
                        markdown: entity, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    {
                        value = String(parsed.characters)
                        sourceRange.length = (entity as NSString).length
                    }
                }
            }
            let length = (value as NSString).length
            units.append((NSRange(location: renderedOffset, length: length), sourceRange))
            decoded += value
            renderedOffset += length
            sourceOffset = NSMaxRange(sourceRange)
        }
        guard decoded == rendered else { return nil }
        let selectedUnits = units.filter { NSIntersectionRange($0.display, selection).length > 0 }
        guard let first = selectedUnits.first, let last = selectedUnits.last else { return "" }
        return input.substring(
            with: NSRange(location: first.source.location, length: NSMaxRange(last.source) - first.source.location))
    }
}

/// Citation decoration replaces selected display spans while keeping original
/// inline offsets. A partial selection inside a citation copies that citation as
/// one source token, rather than manufacturing a different timestamp.
final class MarkdownInlineCopyContext {
    struct Edit {
        var original: NSRange
        var replacementLength: Int
    }
    let map: MarkdownSelectionSourceMap
    var edits: [Edit]
    init(source: String, edits: [Edit] = []) {
        map = MarkdownSelectionSourceMap(source: source)
        self.edits = edits
    }
    func markdown(in transformedSelection: NSRange) -> String {
        guard transformedSelection.location != NSNotFound, transformedSelection.length > 0 else { return "" }
        var start = transformedSelection.location
        var end = NSMaxRange(transformedSelection)
        var shift = 0
        for edit in edits.sorted(by: { $0.original.location < $1.original.location }) {
            let lower = edit.original.location + shift
            let upper = lower + edit.replacementLength
            let delta = edit.original.length - edit.replacementLength
            if transformedSelection.location >= upper {
                start += delta
            }
            else if transformedSelection.location >= lower {
                start = edit.original.location
            }
            if NSMaxRange(transformedSelection) > lower && NSMaxRange(transformedSelection) <= upper {
                end = NSMaxRange(edit.original)
            }
            else if NSMaxRange(transformedSelection) > upper {
                end += delta
            }
            shift -= delta
        }
        return map.markdown(in: NSRange(location: max(0, start), length: max(0, end - start)))
    }
}
