import CryptoKit
import Foundation

struct ArchiveAudio: Codable {
    let filename: String
    let path: String
    let sha256: String
    let size: UInt64
    var url: URL?
}
/// `server-archive.json` in the meeting folder. It is written when an archive is
/// prepared, after each upload, and after the server verifies the archive.
struct ArchiveCheckpoint: Codable {
    let origin: String
    let externalID: String
    let importKey: String
    let snapshot: Data
    var audio: [ArchiveAudio]
    var omittedNoteImages: Bool? = nil
    /// Set after server verification. Missing in checkpoints written before this
    /// field existed; those show as incomplete until the next Archive to Server.
    var verifiedAt: Date?
}

/// Archive state shown with a meeting. No checkpoint means not archived.
enum MeetingArchiveStatus: Equatable {
    case archived(host: String, date: Date?)
    case incomplete(host: String)

    init(_ checkpoint: ArchiveCheckpoint) {
        let host = URL(string: checkpoint.origin)?.host() ?? checkpoint.origin
        self = checkpoint.verifiedAt.map { .archived(host: host, date: $0) } ?? .incomplete(host: host)
    }
}

extension MeetingStore {
    func archiveCheckpointURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("server-archive.json")
    }
    /// Reads the checkpoint again; an unreadable one counts as incomplete only
    /// when present, so a damaged file still prompts a resume.
    func refreshArchiveStatus(id: UUID) {
        let url = archiveCheckpointURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            archiveStatuses[id] = nil
            return
        }
        if let checkpoint = try? JSONDecoder().decode(ArchiveCheckpoint.self, from: Data(contentsOf: url)) {
            archiveStatuses[id] = MeetingArchiveStatus(checkpoint)
        }
        else {
            archiveStatuses[id] = .incomplete(host: "")
        }
    }
    func refreshArchiveStatuses() {
        archiveStatuses = [:]
        for meeting in meetings { refreshArchiveStatus(id: meeting.id) }
    }
    func archiveToServer(id: UUID) async {
        guard flushNotes() else { return }
        // Only this meeting's own recording blocks archiving; its audio is still being written.
        guard recordingID != id, libraryWritable, !isJobRunning(.importAudio, .meeting(id)),
            let meeting = self.meeting(id: id),
            beginJob(.archive, .meeting(id), progress: "Preparing the meeting archive…")
        else { return }
        errorMessage = nil
        defer {
            endJob(.archive, .meeting(id))
            refreshArchiveStatus(id: id)
        }
        do {
            let server = GdayServerService.shared
            guard let origin = server.origin,
                settings.serviceProviders.contains(where: {
                    $0.kind == .gdayWebsite && $0.isEnabled
                        && (try? ServiceHTTP.origin($0.endpoint).absoluteString) == origin
                })
            else { throw ServiceError("Add and sign in to a Gday Meetings website in Service Providers.") }
            let supportsImages = try await server.ensureArchiveAvailable()
            let folder = directory(for: id)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let checkpointURL = archiveCheckpointURL(for: id)
            var checkpoint: ArchiveCheckpoint
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                checkpoint = try JSONDecoder().decode(ArchiveCheckpoint.self, from: Data(contentsOf: checkpointURL))
                guard checkpoint.origin == origin else {
                    throw ServiceError("Sign in to \(checkpoint.origin) to resume this archive.")
                }
            }
            else {
                var archivedMeeting = meeting
                archivedMeeting.transcriptionAttempt = nil
                // Voice vectors train local recognition; archives retain labels and
                // assignments without sending those vectors to the website.
                for index in archivedMeeting.speakers.indices {
                    archivedMeeting.speakers[index].embedding = nil
                    archivedMeeting.speakers[index].voiceScope = nil
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                func json<T: Encodable>(_ value: T) throws -> Any {
                    try JSONSerialization.jsonObject(with: encoder.encode(value))
                }
                var artifacts: [String: Any] = [
                    "meeting.json": try json(archivedMeeting),
                    "transcript.json": ["segments": try json(meeting.transcript)], "notes.md": meeting.notes,
                    "summary.md": meeting.summary, "todos.json": try json(meeting.todos),
                    "chat.json": try json(meeting.chat),
                ]
                let imageReferences = meeting.notes + "\n" + meeting.summary
                let hasImages = !NotesAssets.tokens(in: imageReferences).isEmpty
                if supportsImages {
                    try NotesImageStore.ensurePreviews(in: meeting.notes, directory: folder)
                    artifacts.merge(try ArchiveNoteImages.artifacts(notes: imageReferences, directory: folder)) {
                        _, new in new
                    }
                }
                let metadata: [String: Any] = [
                    "people": try json(
                        people.filter { person in
                            meeting.personIDs.contains(person.id)
                                || meeting.speakers.contains { $0.personID == person.id }
                        }.map { person in
                            var archived = person
                            archived.voiceSamples = []
                            return archived
                        }),
                    "tags": try json(tags.filter { meeting.tagIDs.contains($0.id) }), "client": "Gday Meetings Swift",
                ]
                let snapshot = try JSONSerialization.data(
                    withJSONObject: [
                        "externalId": id.uuidString, "title": meeting.title,
                        "recordedAt": ISO8601DateFormatter().string(from: meeting.createdAt), "metadata": metadata,
                        "artifacts": artifacts,
                    ], options: [.sortedKeys])
                var audio: [ArchiveAudio] = []
                for (index, file) in audioURLs(for: meeting).enumerated() {
                    setJobProgress(.archive, .meeting(id), "Preparing archive audio \(index + 1)…")
                    // Archive original supported bytes when they fit; transcription
                    // separately prefers compressed upload copies for network efficiency.
                    let prepared = try await prepareServerAudio(file, compressPCM: false)
                    var source = prepared.url
                    if prepared.temporary {
                        defer { try? FileManager.default.removeItem(at: prepared.url) }
                        source = folder.appendingPathComponent("archive-audio-\(index).m4a")
                        // Retain converted bytes so retries use the identical hash and server snapshot.
                        if !FileManager.default.fileExists(atPath: source.path) {
                            try FileManager.default.copyItem(at: prepared.url, to: source)
                        }
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                    }
                    let hashed = try await Self.archiveHash(source)
                    audio.append(
                        ArchiveAudio(
                            filename: source.lastPathComponent, path: source.lastPathComponent, sha256: hashed.hash,
                            size: hashed.size))
                }
                checkpoint = ArchiveCheckpoint(
                    origin: origin, externalID: id.uuidString,
                    importKey: ArchiveNoteImages.importKey(snapshot: snapshot, audio: audio), snapshot: snapshot,
                    audio: audio, omittedNoteImages: hasImages && !supportsImages)
                // Reserve the maximum protocol URL size before uploading audio;
                // the exact serialized body is checked again before submission.
                var estimate = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
                estimate["importKey"] = checkpoint.importKey
                estimate["audio"] = audio.map {
                    [
                        "filename": $0.filename, "url": String(repeating: "/", count: 4096), "sha256": $0.sha256,
                        "size": $0.size,
                    ] as [String: Any]
                }
                _ = try ArchiveNoteImages.requestData(estimate)
                try Self.saveArchive(checkpoint, to: checkpointURL)
            }
            if checkpoint.omittedNoteImages == nil,
                let oldBody = try JSONSerialization.jsonObject(with: checkpoint.snapshot) as? [String: Any],
                let oldArtifacts = oldBody["artifacts"] as? [String: Any],
                let notes = oldArtifacts["notes.md"] as? String
            {
                let summary = oldArtifacts["summary.md"] as? String ?? ""
                checkpoint.omittedNoteImages = NotesAssets.tokens(in: notes + "\n" + summary).contains {
                    oldArtifacts[$0.path] == nil
                }
            }
            for index in checkpoint.audio.indices where checkpoint.audio[index].url == nil {
                let item = checkpoint.audio[index]
                guard URL(fileURLWithPath: item.path).lastPathComponent == item.path else {
                    throw ServiceError("The archive audio path is invalid.")
                }
                let source = folder.appendingPathComponent(item.path)
                let hash = try await Self.archiveHash(source)
                guard hash.hash == item.sha256, hash.size == item.size else {
                    throw ServiceError(
                        "Audio changed after this archive was prepared. The original snapshot has been preserved locally."
                    )
                }
                setJobProgress(
                    .archive, .meeting(id), "Uploading archive audio \(index + 1) of \(checkpoint.audio.count)…")
                checkpoint.audio[index].url = try await server.upload(file: source)
                try Self.saveArchive(checkpoint, to: checkpointURL)
            }
            guard var body = try JSONSerialization.jsonObject(with: checkpoint.snapshot) as? [String: Any],
                let artifacts = body["artifacts"] as? [String: Any]
            else { throw ServiceError("The saved archive is invalid.") }
            body["importKey"] = checkpoint.importKey
            body["audio"] = checkpoint.audio.map {
                ["filename": $0.filename, "url": $0.url!.absoluteString, "sha256": $0.sha256, "size": $0.size]
                    as [String: Any]
            }
            setJobProgress(.archive, .meeting(id), "Saving the archive to the server…")
            _ = try await server.importArchive(body)
            setJobProgress(.archive, .meeting(id), "Verifying the archived meeting and audio…")
            let verified = try await server.verifyArchive(externalID: checkpoint.externalID)
            guard verified["importKey"] as? String == checkpoint.importKey,
                verified["audioCount"] as? Int == checkpoint.audio.count,
                verified["artifactCount"] as? Int == artifacts.count
            else {
                throw ServiceError(
                    "The server archive could not be verified. Local files have been preserved; retry to verify.")
            }
            checkpoint.verifiedAt = Date()
            try Self.saveArchive(checkpoint, to: checkpointURL)
            if checkpoint.omittedNoteImages == true {
                errorMessage =
                    "Meeting text and audio were archived. Images linked from Notes or Summary weren’t archived because this server doesn’t support image attachments. Export the meeting to keep a portable copy with its images."
            }
        }
        catch {
            errorMessage =
                "Couldn’t finish archiving this meeting. The meeting and audio on this Mac are kept. Choose Archive to Server to resume. \(error.localizedDescription)"
        }
    }
    private static func saveArchive(_ checkpoint: ArchiveCheckpoint, to url: URL) throws {
        let bytes = try JSONEncoder().encode(checkpoint)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private nonisolated static func archiveHash(_ url: URL) async throws -> (hash: String, size: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            count += UInt64(data.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
