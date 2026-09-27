import Foundation

struct NotesAssetToken {
    var range: NSRange
    var path: String
}

/// Shared by the editor, exports, archives, and cleanup. It never fetches URLs.
enum NotesAssets {
    static func tokens(in markdown: String) -> [NotesAssetToken] {
        let source = markdown as NSString
        let excluded = codeRanges(in: markdown)
        func visible(_ range: NSRange) -> Bool {
            !excluded.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var values: [NotesAssetToken] = []
        func collect(_ pattern: String, in range: NSRange, group: Int) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: markdown, range: range) where visible(match.range) {
                let capture = match.range(at: group)
                guard capture.location != NSNotFound else { continue }
                let raw = source.substring(with: capture)
                let decoded = decodeHTML(raw).removingPercentEncoding ?? decodeHTML(raw)
                // External and fragment references remain literal and are never fetched.
                if let scheme = URLComponents(string: decoded)?.scheme, !scheme.isEmpty { continue }
                if decoded.hasPrefix("//") || decoded.hasPrefix("#") { continue }
                values.append(.init(range: capture, path: decoded))
            }
        }
        collect(
            #"!\[(?:\\.|[^\]\\\n])*\]\(<?([^\s<>\)]+)>?(?:\s+\"[^\"]*\")?\)"#,
            in: NSRange(location: 0, length: source.length), group: 1)
        if let tags = try? NSRegularExpression(pattern: #"<[A-Za-z][^>\n]*>"#) {
            for tag in tags.matches(in: markdown, range: NSRange(location: 0, length: source.length))
            where visible(tag.range) {
                let text = source.substring(with: tag.range).lowercased()
                let attribute: String
                if text.hasPrefix("<img") {
                    attribute = "src"
                }
                else if text.hasPrefix("<a ") {
                    let tail = source.substring(from: NSMaxRange(tag.range))
                    guard let close = tail.range(of: "</a>", options: .caseInsensitive),
                        tail[..<close.lowerBound].range(of: "<img", options: .caseInsensitive) != nil
                    else { continue }
                    attribute = "href"
                }
                else {
                    continue
                }
                collect("(?i)\\b" + attribute + #"\s*=\s*"([^"]*)""#, in: tag.range, group: 1)
                collect("(?i)\\b" + attribute + #"\s*=\s*'([^']*)'"#, in: tag.range, group: 1)
            }
        }
        return values.sorted { $0.range.location < $1.range.location }
    }
    static func safeURL(relativePath: String, directory: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.first == "assets",
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }),
            relativePath.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw MeetingError.message("An image path must stay inside this meeting’s assets folder.") }
        var url = directory
        for component in components {
            url.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw MeetingError.message("Images in notes can’t use symbolic links.")
            }
        }
        // A dangling symlink also must not become a writable asset destination.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw MeetingError.message("Images in notes can’t use symbolic links.")
        }
        return url
    }
    static func referencedFiles(in markdown: String, directory: URL) throws -> [String: URL] {
        var result: [String: URL] = [:]
        for token in tokens(in: markdown) {
            let url = try safeURL(relativePath: token.path, directory: directory)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw MeetingError.message("An image in notes is missing: \(url.lastPathComponent).")
            }
            result[token.path] = url
        }
        return result
    }
    static func rewritingReferences(in markdown: String, paths: [String: String]) -> String {
        let output = NSMutableString(string: markdown)
        for token in tokens(in: markdown).reversed() {
            if let path = paths[token.path] { output.replaceCharacters(in: token.range, with: encodedPath(path)) }
        }
        return output as String
    }
    static func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#\"'<>[]()&")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
    static func decodeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
    static func escapedHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func codeRanges(in markdown: String) -> [NSRange] {
        let source = markdown as NSString
        var excluded: [NSRange] = []
        var fence: (Character, Int)?
        var position = 0
        for line in markdown.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: position, length: min(length + 1, source.length - position))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let char = trimmed.first
            let count = char.map { first in trimmed.prefix { $0 == first }.count } ?? 0
            if let current = fence {
                excluded.append(range)
                if char == current.0, count >= current.1 { fence = nil }
            }
            else if char == "`" || char == "~", count >= 3, let char {
                fence = (char, count)
                excluded.append(range)
            }
            if !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                let lineSource = line as NSString
                var cursor = 0
                while cursor < length {
                    guard lineSource.character(at: cursor) == 96 else {
                        cursor += 1
                        continue
                    }
                    let opening = cursor
                    while cursor < length, lineSource.character(at: cursor) == 96 { cursor += 1 }
                    let run = cursor - opening
                    var search = cursor
                    while search < length {
                        guard lineSource.character(at: search) == 96 else {
                            search += 1
                            continue
                        }
                        let closing = search
                        while search < length, lineSource.character(at: search) == 96 { search += 1 }
                        if search - closing == run {
                            excluded.append(NSRange(location: position + opening, length: search - opening))
                            cursor = search
                            break
                        }
                    }
                }
            }
            position += length + 1
        }
        return excluded
    }
}

struct NotesImageReference: Equatable {
    var range: NSRange
    var originalPath: String
    var displayPath: String
    var width: Double?
    var alt: String

    var markdown: String {
        if let width, width.isFinite, width >= 1, width <= 100_000 {
            return
                "<a href=\"\(NotesAssets.encodedPath(originalPath))\"><img src=\"\(NotesAssets.encodedPath(displayPath))\" width=\"\(Int(width.rounded()))\" alt=\"\(NotesAssets.escapedHTML(alt))\"></a>"
        }
        let label = alt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "![\(label)](\(NotesAssets.encodedPath(originalPath)))"
    }
    static func parse(in markdown: String) -> [Self] {
        let source = markdown as NSString
        let excluded = NotesAssets.codeRanges(in: markdown)
        var result: [Self] = []
        let patterns = [
            #"(?m)^\s*(!\[((?:\\.|[^\]\\\n])*)\]\(<?([^\s<>\)]+)>?\))[^\S\n]*$"#,
            #"(?m)^\s*(<a\s+href=\"([^\"]+)\"><img\s+src=\"([^\"]+)\"\s+width=\"([0-9.]+)\"\s+alt=\"([^\"]*)\"\s*/?></a>)[^\S\n]*$"#,
        ]
        for (kind, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)) {
                let range = match.range(at: 1)
                guard !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                func value(_ index: Int) -> String { source.substring(with: match.range(at: index)) }
                let original = NotesAssets.decodeHTML(value(kind == 0 ? 3 : 2)).removingPercentEncoding ?? ""
                let display = kind == 0 ? original : (NotesAssets.decodeHTML(value(3)).removingPercentEncoding ?? "")
                guard original.hasPrefix("assets/"), display.hasPrefix("assets/") else { continue }
                let width = kind == 0 ? nil : Double(value(4))
                if kind == 1, !(width.map { $0.isFinite && $0 >= 1 && $0 <= 100_000 } ?? false) { continue }
                let alt =
                    kind == 0
                    ? value(2).replacingOccurrences(of: #"\\([\[\]\\])"#, with: "$1", options: .regularExpression)
                    : NotesAssets.decodeHTML(value(5))
                result.append(.init(range: range, originalPath: original, displayPath: display, width: width, alt: alt))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
}
