import Foundation

/// Markdown stays the source of truth. Only valid, namespaced timeline comments
/// are hidden; damaged markers and unrelated HTML are ordinary editable text.
struct NotesDocument: Equatable {
    struct PhraseMarker: Equatable {
        var offset: Int
        var time: TimeInterval
        var raw: String
    }
    struct Line: Equatable {
        var text: String
        var prefix = ""
        var suffix = ""
        var time: TimeInterval?
        var newline = ""
        var markers: [PhraseMarker] = []
        var markdown: String {
            guard !markers.isEmpty else { return prefix + text + suffix + newline }
            let source = text as NSString
            var result = prefix
            var cursor = 0
            for marker in markers {
                let end = min(source.length, max(cursor, marker.offset))
                result += source.substring(with: NSRange(location: cursor, length: end - cursor)) + marker.raw
                cursor = end
            }
            return result + source.substring(from: cursor) + newline
        }
        var hasContent: Bool { NotesDocument.hasContent(text) }
    }
    var lines: [Line]
    private static let marker = try! NSRegularExpression(
        pattern: #"( ?<!-- gday:t=((?:\d+:)?\d{1,2}:\d{2}(?:\.\d+)?) -->)"#)

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
            if let token = fence, Self.closesFence(trimmed, token: token) {
                fence = nil
            }
            else if fence == nil, let fenceToken {
                fence = fenceToken
            }
            let codeRanges = NotesAssets.codeRanges(in: text)
            let matches =
                isCode
                ? []
                : Self.marker.matches(in: text, range: range).filter { match in
                    !codeRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
                }
            var visible = ""
            var markers: [PhraseMarker] = []
            var cursor = text.startIndex
            for match in matches {
                guard let timeRange = Range(match.range(at: 2), in: text),
                    let markerRange = Range(match.range(at: 1), in: text),
                    let time = Self.seconds(String(text[timeRange]))
                else { continue }
                visible += text[cursor..<markerRange.lowerBound]
                markers.append(PhraseMarker(offset: visible.utf16.count, time: time, raw: String(text[markerRange])))
                cursor = markerRange.upperBound
            }
            visible += text[cursor...]
            if markers.count == 1, let only = markers.first, only.offset == visible.utf16.count {
                lines.append(Line(text: visible, suffix: only.raw, time: only.time, newline: ending))
            }
            else {
                lines.append(Line(text: visible, time: markers.first?.time, newline: ending, markers: markers))
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
            if !line.markers.isEmpty {
                let text = line.text as NSString
                var cursor = 0
                var result = ""
                for marker in line.markers {
                    let end = min(text.length, max(cursor, marker.offset))
                    result +=
                        "[\(Self.timestamp(marker.time))] "
                        + text.substring(with: NSRange(location: cursor, length: end - cursor))
                    cursor = end
                }
                return result + text.substring(from: cursor) + line.newline
            }
            return (line.time.map { "[\(Self.timestamp($0))]" + (line.prefix.isEmpty ? " " : "\n") } ?? "") + line.text
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
    /// Resolve all block timestamps in one pass when reading a complete document.
    var lineTimes: [TimeInterval?] {
        var scan = TimedBlockScan()
        return lines.indices.map { lines[scan.line(at: $0, in: lines)].time }
    }

    func timedLine(for line: Int) -> Int {
        var scan = TimedBlockScan()
        var result = line
        for index in 0...min(line, lines.count - 1) {
            result = scan.line(at: index, in: lines)
        }
        return result
    }

    private struct TimedBlockScan {
        var block: Int?
        var fence: String?

        mutating func line(at index: Int, in lines: [Line]) -> Int {
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            if let token = fence {
                // The closing fence still belongs to the block it closes.
                let result = block ?? index
                if NotesDocument.closesFence(text, token: token) {
                    fence = nil
                    block = nil
                }
                return result
            }
            if let token = NotesDocument.fenceToken(text) {
                fence = token
                block = index
            }
            else if NotesDocument.isTableStart(lines, index) {
                block = index
            }
            else if !text.contains("|") {
                block = nil
            }
            return block ?? index
        }
    }
    func time(atLine line: Int) -> TimeInterval? { lines[timedLine(for: line)].time }
    func time(at location: Int) -> TimeInterval? {
        let line = lineIndex(at: location)
        let relative = location - range(of: line).location
        guard !lines[line].markers.isEmpty else { return time(atLine: line) }
        if let marker = lines[line].markers.first(where: { relative < $0.offset }) { return marker.time }
        return relative == lines[line].text.utf16.count && lines[line].markers.last?.offset == relative
            ? lines[line].markers.last?.time : nil
    }
    /// Copies visible text while clipping each phrase boundary to the selection.
    func slice(_ selection: NSRange) -> Self {
        let source = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= source.length else { return Self("") }
        var result = Self(source.substring(with: selection))
        for index in result.lines.indices where result.lines[index].hasContent {
            let absolute = selection.location + result.range(of: index).location
            let oldIndex = lineIndex(at: absolute)
            let relative = absolute - range(of: oldIndex).location
            let end = relative + result.lines[index].text.utf16.count
            let original = lines[oldIndex]
            if original.markers.isEmpty {
                result.setTime(time(at: absolute), line: index)
            }
            else {
                var previous = 0
                var clipped: [PhraseMarker] = []
                for marker in original.markers {
                    if marker.offset > relative && previous < end {
                        var copy = marker
                        copy.offset = min(end, marker.offset) - relative
                        clipped.append(copy)
                    }
                    previous = marker.offset
                }
                result.lines[index].markers = clipped
                result.lines[index].time = clipped.first?.time
                result.lines[index].suffix = ""
            }
        }
        return result
    }

    /// Apply private clipboard times after NSTextView has inserted its visible
    /// text, keeping native undo responsible for the actual text mutation.
    mutating func applyCopiedTimes(_ copied: Self, at location: Int) {
        for index in copied.lines.indices where copied.lines[index].hasContent {
            let start = location + copied.range(of: index).location
            let end = start + copied.lines[index].text.utf16.count
            let target = lineIndex(at: start)
            let base = range(of: target).location
            let lower = start - base
            let upper = end - base
            let beforeTime = lower > 0 ? time(at: start - 1) : nil
            var existing = lines[target].markers
            if existing.isEmpty, let time = lines[target].time {
                existing = [
                    PhraseMarker(
                        offset: lines[target].text.utf16.count, time: time,
                        raw: " <!-- gday:t=\(Self.timestamp(time)) -->")
                ]
            }
            existing.removeAll { $0.offset > lower && $0.offset <= upper }
            if let beforeTime, !existing.contains(where: { $0.offset == lower }) {
                existing.append(
                    PhraseMarker(
                        offset: lower, time: beforeTime,
                        raw: " <!-- gday:t=\(Self.timestamp(beforeTime)) -->"))
            }
            var inserted = copied.lines[index].markers
            if inserted.isEmpty, let time = copied.time(atLine: index) {
                inserted = [
                    PhraseMarker(
                        offset: copied.lines[index].text.utf16.count, time: time,
                        raw: " <!-- gday:t=\(Self.timestamp(time)) -->")
                ]
            }
            existing += inserted.map { marker in
                var value = marker
                value.offset += lower
                return value
            }
            lines[target].markers = existing.filter { $0.offset > 0 }.sorted { $0.offset < $1.offset }
            lines[target].time = lines[target].markers.first?.time
            lines[target].suffix = ""
            lines[target].prefix = ""
        }
        normalizeBlocks()
    }
    mutating func setTime(_ time: TimeInterval?, line: Int) {
        guard lines.indices.contains(line) else { return }
        let line = timedLine(for: line)
        lines[line].time = time
        lines[line].markers = []
        lines[line].prefix = ""
        lines[line].suffix = time.map { " <!-- gday:t=\(Self.timestamp($0)) -->" } ?? ""
        normalizeBlocks()
    }
    /// Edits are in displayed UTF-16 coordinates, as required by NSTextView.
    /// Existing nonempty line fragments keep their time; a new line gets its
    /// clock only when it receives text. Splitting a line inherits both halves.
    mutating func replace(
        _ range: NSRange, with inserted: String, clock: TimeInterval?, phraseClock: TimeInterval? = nil
    ) {
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
        let newPhrase = phraseClock.flatMap { time -> TimeInterval? in
            guard range.length == 0, range.location == NSMaxRange(startRange), original.hasContent,
                original.time != nil,
                !inserted.isEmpty, !inserted.contains("\n"), timedLine(for: start) == start,
                !Self.isFence(original.text), !Self.isTableStart(lines, start),
                time.isFinite, time >= 0, time <= 1_000_000_000_000
            else { return nil }
            return time
        }
        var phraseMarkers: [(Int, PhraseMarker)] = []
        for index in start...end {
            let base = self.range(of: index).location
            var markers = lines[index].markers
            if index == start, newPhrase != nil, markers.isEmpty, let time = original.time {
                markers = [PhraseMarker(offset: original.text.utf16.count, time: time, raw: original.suffix)]
            }
            var previousOffset = 0
            for marker in markers {
                let position = base + marker.offset
                let phraseStart = base + previousOffset
                previousOffset = marker.offset
                if inserted.isEmpty, range.length > 0,
                    range.location <= phraseStart, NSMaxRange(range) >= position
                {
                    continue
                }
                let mapped: Int
                if position < range.location || (newPhrase != nil && position == range.location) {
                    mapped = position
                }
                else if position <= NSMaxRange(range) {
                    mapped = range.location + inserted.utf16.count
                }
                else {
                    mapped = position + inserted.utf16.count - range.length
                }
                phraseMarkers.append((mapped, marker))
            }
        }
        if let time = newPhrase {
            phraseMarkers.append(
                (
                    range.location + inserted.utf16.count,
                    PhraseMarker(offset: 0, time: time, raw: " <!-- gday:t=\(Self.timestamp(time)) -->")
                ))
        }
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
                if inherited && !original.markers.isEmpty {
                    line.time = index == 0 ? original.time : time(at: range.location)
                    line.suffix = line.time.map { " <!-- gday:t=\(Self.timestamp($0)) -->" } ?? ""
                }
            }
            replacement.append(line)
        }
        lines.replaceSubrange(start...end, with: replacement)
        for (position, var marker) in phraseMarkers {
            let line = lineIndex(at: position)
            guard lines[line].hasContent else { continue }
            marker.offset = min(lines[line].text.utf16.count, max(0, position - self.range(of: line).location))
            lines[line].markers.append(marker)
            lines[line].suffix = ""
            lines[line].time = lines[line].markers.first?.time
        }
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
                if !lines[index].markers.isEmpty, let time = lines[index].markers.first?.time {
                    lines[index].prefix = "<!-- gday:t=\(Self.timestamp(time)) -->\n"
                    lines[index].time = time
                    lines[index].markers = []
                    lines[index].suffix = ""
                }
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
                lines[index].markers = []
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
