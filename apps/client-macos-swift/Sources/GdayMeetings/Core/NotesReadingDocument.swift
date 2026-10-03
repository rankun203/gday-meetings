import Foundation

/// A small block reader for the Markdown forms authored by the notes editor.
/// Inline formatting uses Foundation's Markdown parser in the view.
struct NotesReadingDocument {
    enum Alignment { case leading, center, trailing }
    enum Content {
        case text(String)
        case literal(String)
        case heading(String, Int)
        case list(String, String)
        case quote(String)
        case code(String)
        case divider
        case image(NotesImageReference)
        case table([[String]], [Alignment])
    }
    struct Block: Identifiable {
        var id: Int
        var time: TimeInterval?
        var content: Content
    }
    var blocks: [Block] = []
    init(_ markdown: String) {
        let document = NotesDocument(markdown)
        let lines = document.lines
        let times = document.lineTimes
        var index = 0
        while index < lines.count {
            let text = lines[index].text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let start = index
            let time = times[index]
            func append(_ content: Content) { blocks.append(.init(id: start, time: time, content: content)) }
            defer { index += 1 }
            if trimmed.isEmpty { continue }
            if text.hasPrefix("    ") || text.hasPrefix("\t")
                || (text.hasPrefix("  ")
                    && trimmed.range(of: #"^(?:[-+*]|\d+\.|>)\s"#, options: .regularExpression) != nil)
            {
                append(.literal(text))
            }
            else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let token = String(trimmed.prefix { $0 == trimmed.first! })
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let closing = lines[index].text.trimmingCharacters(in: .whitespaces)
                    if closing.hasPrefix(token), closing.dropFirst(token.count).allSatisfy({ $0 == token.first! }) {
                        break
                    }
                    code.append(lines[index].text)
                    index += 1
                }
                append(.code(code.joined(separator: "\n")))
            }
            else if index + 1 < lines.count, let alignment = Self.tableAlignment(lines[index + 1].text),
                Self.cells(text).count == alignment.count
            {
                var rows = [Self.cells(text)]
                index += 1
                while index + 1 < lines.count, lines[index + 1].text.contains("|"),
                    !lines[index + 1].text.trimmingCharacters(in: .whitespaces).isEmpty
                {
                    index += 1
                    var cells = Self.cells(lines[index].text)
                    cells = Array(cells.prefix(alignment.count))
                    cells += Array(repeating: "", count: max(0, alignment.count - cells.count))
                    rows.append(cells)
                }
                append(.table(rows, alignment))
            }
            else if let image = NotesImageReference.parse(in: text).first,
                (text as NSString).substring(with: image.range).trimmingCharacters(in: .whitespaces) == trimmed
            {
                append(.image(image))
            }
            else if text.contains("![") || text.lowercased().contains("<img") {
                append(.literal(text))
            }
            else if Self.containsHTMLOutsideCode(text) {
                // This focused reader does not reinterpret nested block/HTML
                // structure. Keep its source visible rather than flatten it.
                append(.literal(text))
            }
            else if let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                append(.heading(String(trimmed[match.upperBound...]), trimmed[match].filter { $0 == "#" }.count))
            }
            else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                append(.divider)
            }
            else if trimmed.hasPrefix("> ") {
                append(.quote(String(trimmed.dropFirst(2))))
            }
            else if let match = trimmed.range(of: #"^(?:[-+*]|\d+\.)\s+(?:\[[ xX]\]\s+)?"#, options: .regularExpression)
            {
                let prefix = String(trimmed[match])
                let bullet =
                    prefix.contains("[ ]")
                    ? "☐"
                    : (prefix.lowercased().contains("[x]")
                        ? "☑" : (prefix.first?.isNumber == true ? prefix.trimmingCharacters(in: .whitespaces) : "•"))
                append(.list(String(trimmed[match.upperBound...]), bullet))
            }
            else {
                append(.text(text))
            }
        }
    }
    private static func containsHTMLOutsideCode(_ source: String) -> Bool {
        // Angle-bracket placeholders inside code spans are literal code, not HTML.
        let pattern = #"(`+)([\s\S]*?)\1(?!`)"#
        let code = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let withoutCode = code?.stringByReplacingMatches(in: source, range: range, withTemplate: "") ?? source
        return withoutCode.range(of: #"<[!/A-Za-z][^>]*>"#, options: .regularExpression) != nil
    }

    static func cells(_ line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|"), !source.hasSuffix("\\|") { source.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var code = false
        for character in source {
            if escaped {
                cell.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                cell.append(character)
                continue
            }
            if character == "`" { code.toggle() }
            if character == "|", !code {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            }
            else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
    static func tableAlignment(_ line: String) -> [Alignment]? {
        let columns = cells(line)
        guard line.contains("|"), !columns.isEmpty,
            columns.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil })
        else { return nil }
        return columns.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .trailing) : .leading }
    }
}
