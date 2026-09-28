import Foundation

final class MarkdownCopyBlock: NSObject {
    enum Kind {
        case text(prefix: String)
        case code(language: String)
        case table
        case atomic
    }
    struct Cell {
        var range: NSRange
        var row: Int
        var column: Int
        var context: MarkdownInlineCopyContext
    }
    let source: String
    let kind: Kind
    var cells: [Cell]
    init(source: String, kind: Kind, cells: [Cell] = []) {
        self.source = source
        self.kind = kind
        self.cells = cells
    }
}

extension NSAttributedString.Key {
    static let markdownCopyBlock = NSAttributedString.Key("GdayMarkdownCopyBlock")
    static let markdownInlineCopy = NSAttributedString.Key("GdayMarkdownInlineCopy")
}

enum MarkdownReadingSelectionCopy {
    static func markdown(from text: NSAttributedString, selection: NSRange) -> String {
        guard selection.location != NSNotFound, selection.length > 0, selection.location < text.length else {
            return ""
        }
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: text.length))
        var fragments: [(text: String, list: Bool)] = []
        text.enumerateAttribute(.markdownCopyBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let intersection = NSIntersectionRange(range, selected)
            guard intersection.length > 0, let block = value as? MarkdownCopyBlock else { return }
            let body = (text.string as NSString).substring(with: range)
            let contentLength = (String(body.reversed().drop(while: { $0.isNewline }).reversed()) as NSString).length
            let all = intersection.location == range.location && intersection.length >= contentLength
            let copied: String
            var list = false
            switch block.kind {
            case .atomic:
                copied = block.source
            case .text(let prefix):
                list = prefix.range(of: #"^\s*(?:[-+*]|\d+[.)])\s"#, options: .regularExpression) != nil
                let selectedInline = all ? "" : inline(text, selection: intersection)
                copied = all ? block.source : selectedInline.isEmpty ? "" : prefix + selectedInline
            case .code(let language):
                if all {
                    copied = block.source
                }
                else {
                    let code = (text.string as NSString).substring(with: intersection).trimmingCharacters(in: .newlines)
                    let longest =
                        code.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max()
                        ?? 0
                    let fence = String(repeating: "`", count: max(3, longest + 1))
                    copied =
                        fence + (language.components(separatedBy: .newlines).first ?? "") + "\n" + code + "\n" + fence
                }
            case .table:
                copied =
                    all
                    ? block.source
                    : table(
                        block,
                        selection: NSRange(
                            location: intersection.location - range.location, length: intersection.length))
            }
            if !copied.isEmpty { fragments.append((copied, list)) }
        }
        var output = ""
        for index in fragments.indices {
            if index > 0 { output += fragments[index - 1].list && fragments[index].list ? "\n" : "\n\n" }
            output += fragments[index].text.trimmingCharacters(in: .newlines)
        }
        return output
    }

    private static func inline(_ text: NSAttributedString, selection: NSRange) -> String {
        var output = ""
        // Full inline ranges give each context its original local coordinates.
        text.enumerateAttribute(.markdownInlineCopy, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let context = value as? MarkdownInlineCopyContext else { return }
            let part = NSIntersectionRange(range, selection)
            guard part.length > 0 else { return }
            output += context.markdown(in: NSRange(location: part.location - range.location, length: part.length))
        }
        return output
    }

    private static func table(_ block: MarkdownCopyBlock, selection: NSRange) -> String {
        var values: [Int: [Int: String]] = [:]
        var columns = Set<Int>()
        for cell in block.cells {
            let part = NSIntersectionRange(cell.range, selection)
            guard part.length > 0 else { continue }
            let markdown = cell.context.markdown(
                in: NSRange(location: part.location - cell.range.location, length: part.length))
            values[cell.row, default: [:]][cell.column] = markdown
            columns.insert(cell.column)
        }
        guard let firstColumn = columns.min(), let lastColumn = columns.max(), !values.isEmpty else { return "" }
        func row(_ cells: [Int: String]) -> String {
            "| "
                + (firstColumn...lastColumn).map { column in
                    escapeTablePipes(cells[column] ?? "").replacingOccurrences(of: "\n", with: "<br>")
                }.joined(separator: " | ") + " |"
        }
        // Unselected headers stay blank instead of adding unrelated source text.
        var output = [row(values.removeValue(forKey: 0) ?? [:])]
        output.append("| " + (firstColumn...lastColumn).map { _ in "---" }.joined(separator: " | ") + " |")
        for index in values.keys.sorted() { output.append(row(values[index]!)) }
        return output.joined(separator: "\n")
    }

    private static func escapeTablePipes(_ source: String) -> String {
        var output = ""
        var escapes = 0
        for character in source {
            if character == "|", escapes % 2 == 0 { output += "\\" }
            output.append(character)
            escapes = character == "\\" ? escapes + 1 : 0
        }
        return output
    }
}
