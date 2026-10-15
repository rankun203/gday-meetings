import Foundation
import Synchronization

/// A staged compressed replacement committed with its meeting's metadata.
struct CanonicalAudioReplacement: Sendable {
    var meetingID: UUID
    var original: String
    var replacement: String
    var staged: URL
    var originalRevision: String
    var stagedRevision: String

    func validate(directory: URL) throws {
        let folder = MeetingFolderStorage.folder(id: meetingID, directory: directory)
        try MeetingFolderLocation.validate(folder, directory: directory)
        for name in [original, replacement] { try PrivateTranscriptFile.validatePath(name: name, at: folder) }
        guard VoiceLibraryStore.revision(url: folder.appendingPathComponent(original)) == originalRevision,
            VoiceLibraryStore.revision(url: staged) == stagedRevision
        else { throw ServiceError("The audio changed during conversion. Try transcribing again.") }
        if original != replacement
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(replacement).path)
        {
            throw ServiceError(
                "A file already uses the converted audio’s name. Rename that file before transcribing again.")
        }
    }
}

extension MeetingStore {
    /// Conversion happens outside the canonical queue. Only the short publication
    /// owns it; unrelated transcript and title edits remain eligible for merging.
    func prepareAppleTranscriptionAudio(
        id: UUID,
        prepare: @escaping @Sendable (URL) async throws -> PreparedPlaybackAudio
    ) async throws {
        guard let initial = meeting(id: id), libraryWritable, recordingID != id else {
            throw ServiceError("Finish recording before preparing transcription audio.")
        }
        let root = dataDirectory
        let files = audioURLs(for: initial)
        guard !files.isEmpty, files.count == initial.audioFiles.count,
            Set(initial.audioFiles).count == files.count
        else { throw ServiceError("Some meeting audio is missing. Restore it before transcribing.") }
        let folder = directory(for: id)
        try MeetingFolderLocation.validate(folder, directory: root)
        for file in files { try PrivateTranscriptFile.validatePath(name: file.lastPathComponent, at: folder) }
        let revisions = try LocalDiarizationInputPolicy.revisions(for: files)
        var replacements: [CanonicalAudioReplacement] = []
        defer { for replacement in replacements { try? FileManager.default.removeItem(at: replacement.staged) } }
        for file in files {
            try Task.checkCancellation()
            let prepared = try await prepare(file)
            guard prepared.temporary else { continue }
            do {
                try Task.checkCancellation()
                guard let revision = VoiceLibraryStore.revision(url: prepared.url) else {
                    throw ServiceError("The converted audio is unavailable. Try transcribing again.")
                }
                var destination = file.deletingPathExtension().appendingPathExtension(prepared.url.pathExtension)
                if FileManager.default.fileExists(atPath: destination.path)
                    || replacements.contains(where: { $0.replacement == destination.lastPathComponent })
                {
                    destination = file.deletingLastPathComponent().appendingPathComponent(
                        LocalDiarizationInputPolicy.recordingStem(for: file) + "-compatible-" + UUID().uuidString
                    ).appendingPathExtension(prepared.url.pathExtension)
                }
                replacements.append(
                    .init(
                        meetingID: id, original: file.lastPathComponent, replacement: destination.lastPathComponent,
                        staged: prepared.url, originalRevision: revisions[file]!, stagedRevision: revision))
            }
            catch {
                try? FileManager.default.removeItem(at: prepared.url)
                throw error
            }
        }
        guard !replacements.isEmpty else { return }
        let captured = replacements
        let cancelled = Mutex(false)
        let saved = await withTaskCancellationHandler {
            await enqueueCanonical {
                guard !cancelled.withLock({ $0 }), self.dataDirectory == root, self.libraryWritable,
                    let index = self.meetings.firstIndex(where: { $0.id == id }),
                    self.meetings[index].audioFiles == initial.audioFiles,
                    self.meetings[index].transcriptionAttempt == initial.transcriptionAttempt
                else { return false }
                let previous = self.meetings[index]
                var updated = previous
                for replacement in captured {
                    updated.audioFiles = updated.audioFiles.map {
                        $0 == replacement.original ? replacement.replacement : $0
                    }
                    if var profile = updated.recordingProfile {
                        for track in profile.tracks.indices where profile.tracks[track].filename == replacement.original
                        {
                            profile.tracks[track].filename = replacement.replacement
                        }
                        updated.recordingProfile = profile
                    }
                }
                if var attempt = updated.transcriptionAttempt {
                    if let request = attempt.analysisRequest {
                        attempt.supersededAnalysisRequests = (attempt.supersededAnalysisRequests ?? []) + [request]
                    }
                    attempt.analysisRequest = nil
                    attempt.audioReferences = nil
                    attempt.admittedAt = nil
                    attempt.idempotencyKey = UUID().uuidString
                    attempt.requiresAudioAdmission = true
                    updated.transcriptionAttempt = attempt
                }
                self.meetings[index] = updated
                let success = await self.performCanonicalSave(
                    meetingID: id,
                    validateInputs: {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                        for file in files where VoiceLibraryStore.revision(url: file) != revisions[file] {
                            throw ServiceError("The audio changed during conversion. Try transcribing again.")
                        }
                    }, audioReplacements: captured)
                if !success, let position = self.meetings.firstIndex(where: { $0.id == id }) {
                    // Roll back fields this command still owns, preserving later edits.
                    if self.meetings[position].audioFiles == updated.audioFiles {
                        self.meetings[position].audioFiles = previous.audioFiles
                    }
                    if self.meetings[position].recordingProfile == updated.recordingProfile {
                        self.meetings[position].recordingProfile = previous.recordingProfile
                    }
                    if self.meetings[position].transcriptionAttempt == updated.transcriptionAttempt {
                        self.meetings[position].transcriptionAttempt = previous.transcriptionAttempt
                    }
                }
                return success
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        guard saved else {
            throw ServiceError(errorMessage ?? "The meeting changed during conversion. Try transcribing again.")
        }
    }
}
