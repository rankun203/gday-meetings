import Foundation

enum MeetingExportFormat: String, CaseIterable {
    case json, markdown, textBundle
    var title: String {
        switch self {
        case .json: "JSON"
        case .markdown: "Markdown"
        case .textBundle: "TextBundle"
        }
    }
    var fileExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        case .textBundle: "textbundle"
        }
    }
}

extension MeetingStore {
    func exportMeeting(id: UUID, to url: URL) throws {
        guard flushNotes() else { throw MeetingError.message(errorMessage ?? "Couldn’t save meeting notes.") }
        guard var meeting = self.meeting(id: id) else {
            throw MeetingError.message("Meeting no longer exists.")
        }
        meeting.transcriptionAttempt = nil
        for index in meeting.transcript.indices {
            meeting.transcript[index].speaker = meeting.speakerName(for: meeting.transcript[index], people: people)
            meeting.transcript[index].speakerID = nil
        }
        meeting.speakers = []
        try MeetingExport.write(meeting, directory: directory(for: id), to: url)
    }
}

enum MeetingExport {
    static func markdown(_ meeting: Meeting, notes: String) -> String {
        let transcript = meeting.transcript.map {
            let attribution = $0.speaker.isEmpty ? "" : "**\($0.speaker):** "
            return "[\(Int($0.start / 60)):\(String(format: "%02d", Int($0.start) % 60))] \(attribution)\($0.text)"
        }.joined(separator: "\n\n")
        let todos = meeting.todos.map { "- [\($0.isCompleted ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
        return
            "# \(meeting.title)\n\n\(meeting.createdAt.formatted())\n\n## Summary\n\n\(meeting.summary)\n\n## Notes\n\n\(NotesDocument(notes).citedText)\n\n## Action items\n\n\(todos)\n\n## Transcript\n\n\(transcript)\n"
    }

    static func write(_ meeting: Meeting, directory: URL, to url: URL) throws {
        try NotesImageStore.ensurePreviews(in: meeting.notes, directory: directory)
        let files = try NotesAssets.referencedFiles(in: meeting.notes, directory: directory)
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".gday-export-\(UUID().uuidString)")
        try manager.createDirectory(
            at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let format: MeetingExportFormat =
            switch url.pathExtension.lowercased() {
            case "json": .json
            case "textbundle": .textBundle
            default: .markdown
            }
        if format == .textBundle {
            let infoURL = url.appendingPathComponent("info.json")
            guard (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil,
                (try? manager.destinationOfSymbolicLink(atPath: infoURL.path)) == nil
            else {
                throw MeetingError.message("Choose a destination that isn’t a symbolic link.")
            }
            try copy(files, to: stage)
            try Data(markdown(meeting, notes: meeting.notes).utf8).write(
                to: stage.appendingPathComponent("text.markdown"), options: .atomic)
            // Preserve metadata owned by another TextBundle editor on replacement.
            var info: [String: Any] = [:]
            if manager.fileExists(atPath: infoURL.path) {
                guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as? [String: Any]
                else {
                    throw MeetingError.message(
                        "The existing TextBundle metadata isn’t valid. Choose another destination.")
                }
                info = existing
            }
            info["version"] = 2
            info["type"] = "net.daringfireball.markdown"
            info["creatorIdentifier"] = "com.gdaymeetings.macos"
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: stage.appendingPathComponent("info.json"), options: .atomic)
            if manager.fileExists(atPath: url.path) {
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    throw MeetingError.message("Choose a destination that isn’t a symbolic link.")
                }
                _ = try manager.replaceItemAt(url, withItemAt: stage)
            }
            else {
                try manager.moveItem(at: stage, to: url)
            }
            return
        }
        var paths: [String: String] = [:]
        var sidecar: URL?
        if !files.isEmpty {
            let stem = url.deletingPathExtension().lastPathComponent + "-assets"
            var name = stem
            var suffix = 2
            while manager.fileExists(atPath: parent.appendingPathComponent(name).path)
                || (try? manager.destinationOfSymbolicLink(atPath: parent.appendingPathComponent(name).path)) != nil
            {
                name = "\(stem)-\(suffix)"
                suffix += 1
            }
            try copy(files, to: stage)
            sidecar = parent.appendingPathComponent(name)
            for path in files.keys { paths[path] = name + "/" + path.dropFirst("assets/".count) }
        }
        let output: Data
        if format == .json {
            let encoder = JSONEncoder()
            guard var object = try JSONSerialization.jsonObject(with: encoder.encode(meeting)) as? [String: Any] else {
                throw MeetingError.message("Couldn’t prepare the meeting export.")
            }
            if !paths.isEmpty { object["notesAssets"] = paths }
            output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
        else {
            output = Data(
                markdown(meeting, notes: NotesAssets.rewritingReferences(in: meeting.notes, paths: paths)).utf8)
        }
        if let sidecar { try manager.moveItem(at: stage.appendingPathComponent("assets"), to: sidecar) }
        do { try output.write(to: url, options: .atomic) }
        catch {
            if let sidecar { try? manager.removeItem(at: sidecar) }
            throw error
        }
    }

    private static func copy(_ files: [String: URL], to directory: URL) throws {
        for path in files.keys.sorted() {
            let target = try NotesAssets.safeURL(relativePath: path, directory: directory)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: files[path]!, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    /// The manifest is optional, keeping old text-only JSON exports importable.
    static func importAssets(from data: Data, source: URL, notes: String, directory: URL) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["notesAssets"]
        else { return }
        guard let manifest = raw as? [String: String] else {
            throw MeetingError.message("The exported notes image manifest is invalid.")
        }
        let referenced = Set(NotesAssets.tokens(in: notes).map(\.path))
        guard Set(manifest.keys) == referenced else {
            throw MeetingError.message("The exported notes image manifest doesn’t match the notes.")
        }
        var files: [String: URL] = [:]
        for (path, relative) in manifest {
            _ = try NotesAssets.safeURL(relativePath: path, directory: directory)
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let first = parts.first,
                !first.isEmpty, first != ".", first != "..", !first.contains("\\"),
                first.rangeOfCharacter(from: .controlCharacters) == nil,
                parts.dropFirst().joined(separator: "/") == String(path.dropFirst("assets/".count))
            else {
                throw MeetingError.message("An exported image path is outside its assets folder.")
            }
            let sidecar = source.deletingLastPathComponent().appendingPathComponent(first)
            guard (try? sidecar.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                (try? FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path)) == nil
            else {
                throw MeetingError.message("Exported images can’t use symbolic links.")
            }
            // Reuse the canonical resolver by validating each nested component.
            var resolved = sidecar
            for part in parts.dropFirst() {
                guard !part.isEmpty, part != ".", part != "..", !part.contains("\\"),
                    part.rangeOfCharacter(from: .controlCharacters) == nil
                else {
                    throw MeetingError.message("The exported image path is invalid.")
                }
                resolved.appendPathComponent(part)
                guard (try? resolved.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path)) == nil
                else {
                    throw MeetingError.message("Exported images can’t use symbolic links.")
                }
            }
            guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw MeetingError.message("An exported image is missing: \(resolved.lastPathComponent).")
            }
            files[path] = resolved
        }
        try copy(files, to: directory)
    }
}
