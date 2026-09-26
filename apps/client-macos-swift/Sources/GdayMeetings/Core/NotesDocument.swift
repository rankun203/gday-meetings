import Foundation

/// Markdown stays the source of truth. Only valid, namespaced timeline comments
/// are hidden; damaged markers and unrelated HTML are ordinary editable text.
struct NotesDocument: Equatable {
    struct Line: Equatable {
        var text: String
        var prefix = ""
        var suffix = ""
        var time: TimeInterval?
        var newline = ""
        var markdown: String { prefix + text + suffix + newline }
        var hasContent: Bool { NotesDocument.hasContent(text) }
    }
    var lines: [Line]
    private static let marker = try! NSRegularExpression(
        pattern: #"( ?<!-- gday:t=((?:\d+:)?\d{1,2}:\d{2}(?:\.\d+)?) -->)$"#)

    init(_ markdown: String) {
        let parts = markdown.components(separatedBy: "\n")
        lines = []
        var fence: String?
        for index in parts.indices {
            let newline = index < parts.count - 1 ? "\n" : ""
            var text = parts[index]
            let ending = text.hasSuffix("\r") && !newline.isEmpty ? "\r\n" : newline
            if ending == "\r\n" { text.removeLast() }
            let range = NSRange(text.startIndex..., in: text)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let fenceToken = Self.fenceToken(trimmed)
            let isCode = fence != nil
            if fence != nil, fenceToken == fence {
                fence = nil
            }
            else if fence == nil, let fenceToken {
                fence = fenceToken
            }
            if !isCode, let match = Self.marker.firstMatch(in: text, range: range),
                let timeRange = Range(match.range(at: 2), in: text),
                let suffixRange = Range(match.range(at: 1), in: text),
                let time = Self.seconds(String(text[timeRange]))
            {
                lines.append(
                    Line(
                        text: String(text[..<suffixRange.lowerBound]), suffix: String(text[suffixRange]), time: time,
                        newline: ending))
            }
            else {
                lines.append(Line(text: text, newline: ending))
            }
        }
        // A standalone block marker is represented on its following opening
        // line, without exposing an extra blank line in the editor.
        var index = 0
        while index + 1 < lines.count {
            if lines[index].text.isEmpty, lines[index].time != nil,
                Self.isFence(lines[index + 1].text) || Self.isTableStart(lines, index + 1)
            {
                let marker = lines.remove(at: index)
                lines[index].prefix = marker.markdown
                lines[index].time = marker.time
            }
            index += 1
        }
    }
    var markdown: String { lines.map(\.markdown).joined() }
    var text: String { lines.map { $0.text + $0.newline }.joined() }
    var citedText: String {
        lines.map { line in
            (line.time.map { "[\(Self.timestamp($0))]" + (line.prefix.isEmpty ? " " : "\n") } ?? "") + line.text
                + line.newline
        }.joined()
    }
    static func seconds(_ timestamp: String) -> TimeInterval? {
        let rawPieces = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        let pieces = rawPieces.compactMap { Double($0) }
        guard rawPieces.count == pieces.count, (2...3).contains(pieces.count),
            pieces.allSatisfy({ $0.isFinite && $0 >= 0 }),
            pieces.last! < 60, pieces.count == 2 || pieces[1] < 60
        else { return nil }
        let result = pieces.reduce(0) { $0 * 60 + $1 }
        return result <= 1_000_000_000_000 ? result : nil
    }
    static func timestamp(_ time: TimeInterval) -> String {
        let safeTime = time.isFinite ? min(1_000_000_000_000, max(0, time)) : 0
        let tenths = Int((safeTime * 10).rounded())
        let seconds = tenths / 10
        let base =
            seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return tenths % 10 == 0 ? base : "\(base).\(tenths % 10)"
    }
    static func playbackStart(_ time: TimeInterval) -> TimeInterval { max(0, time - 3) }
    static func clock(recording: TimeInterval?, playback: TimeInterval?) -> TimeInterval? {
        let time = recording ?? playback
        return time.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000 ? $0 : nil }
    }
    private static func hasContent(_ text: String) -> Bool {
        let content = text.replacingOccurrences(
            of: #"^\s*(?:[-+*]|\d+\.)(?: \[[ xX]\])? $"#, with: "", options: .regularExpression)
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func lineIndex(at location: Int) -> Int {
        var offset = 0
        for index in lines.indices {
            offset += (lines[index].text + lines[index].newline).utf16.count
            if location < offset { return index }
        }
        return max(0, lines.count - 1)
    }
    func range(of index: Int) -> NSRange {
        NSRange(
            location: lines.prefix(index).reduce(0) { $0 + ($1.text + $1.newline).utf16.count },
            length: lines[index].text.utf16.count)
    }
    func timedLine(for line: Int) -> Int {
        var block: Int?
        var fence: String?
        for index in 0...min(line, lines.count - 1) {
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            if let token = fence {
                if index == line { return block ?? line }
                if Self.closesFence(text, token: token) {
                    fence = nil
                    block = nil
                }
            }
            else if let token = Self.fenceToken(text) {
                fence = token
                block = index
            }
            else if Self.isTableStart(lines, index) {
                block = index
            }
            else if !text.contains("|") {
                block = nil
            }
        }
        return block ?? line
    }
    func time(atLine line: Int) -> TimeInterval? { lines[timedLine(for: line)].time }
    mutating func setTime(_ time: TimeInterval?, line: Int) {
        guard lines.indices.contains(line) else { return }
        let line = timedLine(for: line)
        lines[line].time = time
        lines[line].prefix = ""
        lines[line].suffix = time.map { " <!-- gday:t=\(Self.timestamp($0)) -->" } ?? ""
        normalizeBlocks()
    }
    /// Edits are in displayed UTF-16 coordinates, as required by NSTextView.
    /// Existing nonempty line fragments keep their time; a new line gets its
    /// clock only when it receives text. Splitting a line inherits both halves.
    mutating func replace(_ range: NSRange, with inserted: String, clock: TimeInterval?) {
        let oldText = text as NSString
        guard range.location <= oldText.length, NSMaxRange(range) <= oldText.length else { return }
        let start = lineIndex(at: range.location)
        let end = lineIndex(at: NSMaxRange(range))
        let startRange = self.range(of: start)
        let endRange = self.range(of: end)
        let prefix = oldText.substring(
            with: NSRange(location: startRange.location, length: range.location - startRange.location))
        let tailStart = min(NSMaxRange(range), NSMaxRange(endRange))
        let tail = oldText.substring(with: NSRange(location: tailStart, length: NSMaxRange(endRange) - tailStart))
        let pieces = (prefix + inserted + tail).components(separatedBy: "\n")
        let original = lines[start]
        var replacement: [Line] = []
        for (index, piece) in pieces.enumerated() {
            var line = Line(text: piece, newline: index == pieces.count - 1 ? lines[end].newline : "\n")
            let inherited = index == 0 || (index == pieces.count - 1 && !tail.isEmpty && start == end)
            if Self.hasContent(piece) {
                line.time = inherited && original.hasContent ? original.time : clock
                line.prefix = inherited ? original.prefix : ""
                line.suffix =
                    inherited && original.hasContent
                    ? original.suffix : line.time.map { " <!-- gday:t=\(Self.timestamp($0)) -->" } ?? ""
            }
            replacement.append(line)
        }
        lines.replaceSubrange(start...end, with: replacement)
        normalizeBlocks()
    }
    private static func fenceToken(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard let first = value.first, first == "`" || first == "~" else { return nil }
        let token = String(value.prefix { $0 == first })
        return token.count >= 3 ? token : nil
    }
    private static func closesFence(_ text: String, token: String) -> Bool {
        guard let closing = fenceToken(text), closing.first == token.first, closing.count >= token.count else {
            return false
        }
        return text.trimmingCharacters(in: .whitespaces).dropFirst(closing.count).trimmingCharacters(in: .whitespaces)
            .isEmpty
    }
    private static func isFence(_ text: String) -> Bool { fenceToken(text) != nil }
    private static func isTableStart(_ lines: [Line], _ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].text.contains("|") else { return false }
        return lines[index + 1].text.range(of: #"^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil
    }
    private mutating func normalizeBlocks() {
        var fence: String?
        var table = false
        for index in lines.indices {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            let opening = fence == nil && (Self.isFence(trimmed) || Self.isTableStart(lines, index))
            if opening {
                if !lines[index].suffix.isEmpty {
                    lines[index].prefix =
                        lines[index].suffix.trimmingCharacters(in: .whitespaces)
                        + (lines[index].newline.isEmpty ? "\n" : lines[index].newline)
                    lines[index].suffix = ""
                }
                if Self.isFence(trimmed) {
                    fence = Self.fenceToken(trimmed)
                }
                else {
                    table = true
                }
            }
            else if fence != nil || (table && trimmed.contains("|")) {
                lines[index].time = nil
                lines[index].suffix = ""
                lines[index].prefix = ""
                if let token = fence, Self.closesFence(trimmed, token: token) { fence = nil }
            }
            else {
                table = false
            }
        }
    }
}
