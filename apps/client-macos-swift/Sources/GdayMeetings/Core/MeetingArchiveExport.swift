import Foundation

/// Builds a portable archive in a background task, never on the main actor.
enum MeetingArchiveExport {
    static func filename(for title: String) -> String {
        let normalized = title.replacingOccurrences(of: "[^a-zA-Z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let stem = normalized.isEmpty ? "untitled" : String(normalized.prefix(180))
        return "meeting-\(stem).zip"
    }

    static func write(_ meeting: Meeting, directory: URL, to destination: URL) throws {
        let manager = FileManager.default
        let source = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw MeetingError.message("Choose another folder to save the ZIP.")
        }
        guard !target.hasPrefix(source), target != String(source.dropLast()) else {
            throw MeetingError.message("Save the ZIP outside this meeting’s folder.")
        }
        let started = Date()
        let replacing = manager.fileExists(atPath: destination.path)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".gday-export-\(UUID())")
        try manager.createDirectory(
            at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let content = stage.appendingPathComponent("content")
        try manager.createDirectory(
            at: content, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var snapshot = meeting
        var names = Set<String>()
        for name in meeting.audioFiles {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                name.rangeOfCharacter(from: .controlCharacters) == nil,
                !["index.html", "summary.md", "transcripts.jsonl"].contains(name.lowercased()),
                names.insert(name.lowercased()).inserted
            else { throw MeetingError.message("An audio filename is invalid. Check the meeting’s audio files.") }
            try copyRegularFile(directory.appendingPathComponent(name), to: content.appendingPathComponent(name))
        }
        let transcript = directory.appendingPathComponent(TranscriptStorage.filename)
        let exportedTranscript = content.appendingPathComponent("transcripts.jsonl")
        if manager.fileExists(atPath: transcript.path) {
            try copyRegularFile(transcript, to: exportedTranscript)
            snapshot.transcript = try TranscriptStorage.readRows(exportedTranscript)
        }
        else {
            snapshot.transcript = []
        }
        // The standalone page resolves display names without exporting the people library.
        let labels = Dictionary(meeting.transcript.map { ($0.id, $0.speaker) }, uniquingKeysWith: { first, _ in first })
        for index in snapshot.transcript.indices {
            if let label = labels[snapshot.transcript[index].id] { snapshot.transcript[index].speaker = label }
        }
        let summary = directory.appendingPathComponent("summary.md")
        snapshot.summary = ""
        if manager.fileExists(atPath: summary.path) {
            let exported = content.appendingPathComponent("summary.md")
            try copyRegularFile(summary, to: exported)
            snapshot.summary = try String(contentsOf: exported, encoding: .utf8)
        }
        let assets = try NotesAssets.referencedFiles(in: snapshot.summary, directory: directory)
        for (path, source) in assets {
            let target = try NotesAssets.safeURL(relativePath: path, directory: content)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyRegularFile(source, to: target)
        }
        try Data(try html(snapshot).utf8).write(to: content.appendingPathComponent("index.html"))
        let archive = stage.appendingPathComponent("meeting.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", content.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MeetingError.message("Couldn’t create the ZIP. Check the available disk space and try again.")
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        if replacing {
            _ = try manager.replaceItemAt(destination, withItemAt: archive)
        }
        else {
            try manager.moveItem(at: archive, to: destination)
        }
        do {
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let flow = DataFlow(
                location: .local, targetID: ThisMacProvider.id, targetName: "This Mac", responseBytes: size,
                startedAt: started, endedAt: Date(), bodies: [destination.lastPathComponent],
                purpose: "Meeting ZIP export")
            try DataEventJournal.append(
                MeetingDataEvent(action: replacing ? .modified : .created, dataFlow: flow), directory: directory)
        }
        catch { NotificationCenter.default.post(name: DataEventJournal.writeFailure, object: directory) }
    }

    private static func copyRegularFile(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MeetingError.message("Couldn’t read \(source.lastPathComponent). Check the file and try again.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func html(_ meeting: Meeting) throws -> String {
        guard let templateURL = Bundle.module.url(forResource: "meeting-export", withExtension: "html")
        else { throw MeetingError.message("The meeting viewer template is missing. Reinstall the app and try again.") }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        var speakers: [String: Int] = [:]
        let rows = meeting.transcript.sorted { $0.start < $1.start }.map { row in
            let speaker = row.speaker.isEmpty ? "Unidentified" : row.speaker
            if speakers[speaker] == nil { speakers[speaker] = speakers.count % 7 }
            let time = escape(NotesDocument.timestamp(row.start))
            return """
                <article class="segment" data-start="\(number(row.start))" data-end="\(number(row.end))">
                <button type="button" class="timestamp" aria-label="Play from \(time)">\(time)</button>
                <span class="speaker c\(speakers[speaker]!)">\(escape(speaker))</span><p>\(escape(row.text))</p></article>
                """
        }.joined(separator: "\n")
        var audio: [String] = []
        var controls: [String] = []
        for (index, name) in meeting.audioFiles.enumerated() {
            let path = escape(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            audio.append("<audio id=\"audio-\(index)\" preload=\"metadata\" src=\"\(path)\"></audio>")
            controls.append(
                "<label><input type=\"checkbox\" data-track=\"audio-\(index)\" checked>\(escape(name))</label>")
        }
        let duration = max(
            meeting.duration.isFinite ? meeting.duration : 0,
            meeting.transcript.map(\.end).filter(\.isFinite).max() ?? 0)
        let replacements = [
            "TITLE": escape(meeting.title),
            "DATE": escape(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)),
            "DURATION": number(duration), "DURATION_LABEL": escape(NotesDocument.timestamp(duration)),
            "TRANSCRIPT": rows, "SUMMARY": summaryHTML(meeting.summary),
            "AUDIO": audio.joined(separator: "\n"), "TRACK_CONTROLS": controls.joined(separator: "\n"),
        ]
        // Replace tokens in the original template once; content containing a token remains literal.
        let expression = try NSRegularExpression(pattern: #"\{\{([A-Z_]+)\}\}"#)
        let result = NSMutableString(string: template)
        for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let key = (template as NSString).substring(with: match.range(at: 1))
            guard let value = replacements[key] else {
                throw MeetingError.message("The meeting viewer template is invalid.")
            }
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    private static func number(_ value: Double) -> String { String(value.isFinite ? max(0, value) : 0) }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func inline(_ text: String) -> String {
        let parsed = MarkdownSelectionSourceMap(source: text).parsed
        return parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            let text = String(parsed[run.range].characters)
            var html = intent.contains(.code) || run.link != nil ? escape(text) : citations(text)
            if intent.contains(.code) { html = "<code>\(html)</code>" }
            if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
            if intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
            if let link = run.link, let href = portableLink(link) {
                html = "<a href=\"\(escape(href))\" rel=\"noreferrer\">\(html)</a>"
            }
            return html
        }.joined()
    }

    private static func portableLink(_ link: URL) -> String? {
        if ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") { return link.absoluteString }
        let path = link.path
        guard link.scheme == nil, link.host == nil, path.hasPrefix("assets/"),
            !path.contains("\\"), path.rangeOfCharacter(from: .controlCharacters) == nil,
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
        else { return nil }
        return NotesAssets.encodedPath(path)
    }

    private static func citations(_ text: String) -> String {
        let expression = try! NSRegularExpression(
            pattern: #"[\[【](\d+(?::\d{2}){1,2})(?:\s*[-–—‑]\s*\d+(?::\d{2}){1,2})?[\]】]"#)
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let time = NotesDocument.seconds(source.substring(with: match.range(at: 1))) else { continue }
            result += escape(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let label = escape(source.substring(with: match.range))
            result +=
                "<button type=\"button\" class=\"summary-time\" data-seek=\"\(number(time))\" aria-label=\"Play from \(escape(NotesDocument.timestamp(time)))\">\(label)</button>"
            cursor = NSMaxRange(match.range)
        }
        return result + escape(source.substring(from: cursor))
    }

    static func summaryHTML(_ markdown: String) -> String {
        let blocks = NotesReadingDocument(markdown).blocks
        guard !blocks.isEmpty else { return "<p>No summary available.</p>" }
        return blocks.map { block in
            let time =
                block.time.map {
                    " <button type=\"button\" class=\"summary-time\" data-seek=\"\(number($0))\" aria-label=\"Play from \(escape(NotesDocument.timestamp($0)))\">\(escape(NotesDocument.timestamp($0)))</button>"
                } ?? ""
            switch block.content {
            case .text(let text): return "<p>\(inline(text))\(time)</p>"
            case .literal(let text): return "<p>\(escape(text))\(time)</p>"
            case .heading(let text, let level): return "<h\(level)>\(inline(text))\(time)</h\(level)>"
            case .list(let text, let bullet):
                return "<p class=\"list-item\">\(escape(bullet)) \(inline(text))\(time)</p>"
            case .quote(let text): return "<blockquote>\(inline(text))\(time)</blockquote>"
            case .code(let text): return "\(time)<pre><code>\(escape(text))</code></pre>"
            case .divider: return "<hr>\(time)"
            case .table(let rows, _):
                return time + "<table>"
                    + rows.enumerated().map { index, cells in
                        let tag = index == 0 ? "th" : "td"
                        return "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
                    }.joined() + "</table>"
            case .image(let image):
                guard image.displayPath.hasPrefix("assets/"), image.originalPath.hasPrefix("assets/") else {
                    return "<p>\(escape(image.alt))</p>"
                }
                let path = escape(NotesAssets.encodedPath(image.displayPath))
                let original = escape(NotesAssets.encodedPath(image.originalPath))
                return "<p><a href=\"\(original)\"><img src=\"\(path)\" alt=\"\(escape(image.alt))\"></a>\(time)</p>"
            }
        }.joined(separator: "\n")
    }
}
