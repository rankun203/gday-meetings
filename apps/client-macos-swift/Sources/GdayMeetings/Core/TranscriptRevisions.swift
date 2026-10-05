import Foundation

struct TranscriptSource: Codable, Equatable {
    var id: UUID
    var providerName: String
    var generatedAt: Date
}

struct SpeakerLabelSource: Codable, Equatable {
    var resultID: UUID
    var providerName: String
    var generatedAt: Date
}

struct TranscriptRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var savedAt = Date()
    var title: String
    var source: TranscriptSource? = nil
    var speakerLabelSource: SpeakerLabelSource? = nil
    var segments: [TranscriptSegment]
    var speakers: [MeetingSpeaker]
}
struct TranscriptRevisions: Codable {
    var version = 1
    var revisions: [TranscriptRevision] = []
    static func read(at directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("transcript-revisions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.version == 1 else {
            throw MeetingError.message("The saved transcript revisions use an unsupported format.")
        }
        return result
    }
    static func preserve(_ meeting: Meeting, at directory: URL) throws {
        guard !meeting.transcript.isEmpty else { return }
        var value = try read(at: directory)
        let revision = current(meeting)
        if let index = value.revisions.firstIndex(where: { $0.id == revision.id }) {
            guard value.revisions[index] != revision else { return }
            value.revisions[index] = revision
        }
        else {
            value.revisions.append(revision)
        }
        try PrivateTranscriptFile.write(
            try JSONEncoder().encode(value), name: "transcript-revisions.json", at: directory)
    }
    static func current(_ meeting: Meeting) -> TranscriptRevision {
        TranscriptRevision(
            id: meeting.speakerLabelSource?.resultID ?? meeting.transcriptSource?.id ?? meeting.id,
            savedAt: meeting.transcriptSource?.generatedAt ?? meeting.createdAt,
            title: meeting.transcriptSource?.providerName ?? "Transcript", source: meeting.transcriptSource,
            speakerLabelSource: meeting.speakerLabelSource,
            segments: meeting.transcript, speakers: meeting.speakers)
    }
    static func snapshots(_ revisions: [TranscriptRevision], current meeting: Meeting) -> [TranscriptRevision] {
        let current = current(meeting)
        var values = revisions.filter { $0.id != current.id }
        if !meeting.transcript.isEmpty { values.append(current) }
        let originals = values.filter { !isLegacyLabeling($0) }
        return values.map { revision in
            guard isLegacyLabeling(revision) else { return revision }
            let candidates = originals.filter { sameText($0.segments, revision.segments) }
            let sources = Set(candidates.map { $0.source?.id ?? $0.id })
            // Legacy files have no parent reference. Never guess between runs.
            guard sources.count == 1, let parent = candidates.first else { return revision }
            var resolved = revision
            resolved.speakerLabelSource = .init(
                resultID: revision.id, providerName: "Community-1", generatedAt: revision.savedAt)
            resolved.savedAt = parent.savedAt
            resolved.source =
                parent.source
                ?? .init(
                    id: parent.id, providerName: "Transcript", generatedAt: parent.savedAt)
            return resolved
        }
    }

    static func isLegacyLabeling(_ revision: TranscriptRevision) -> Bool {
        revision.speakerLabelSource == nil && revision.source?.providerName == "Community-1 Speaker Labeling"
    }

    static func sameText(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy {
                $0.id == $1.id && $0.text == $1.text && $0.start == $1.start && $0.end == $1.end
                    && $0.source == $1.source && $0.session == $1.session
            }
    }

    static func choices(_ revisions: [TranscriptRevision], current meeting: Meeting) -> [TranscriptRevision] {
        let currentID = current(meeting).id
        let sources = Dictionary(grouping: snapshots(revisions, current: meeting)) { $0.source?.id ?? $0.id }
        var choices: [TranscriptRevision] = []
        for source in sources.values {
            var textGroups: [[TranscriptRevision]] = []
            for snapshot in source {
                if let index = textGroups.firstIndex(where: { sameText($0[0].segments, snapshot.segments) }) {
                    textGroups[index].append(snapshot)
                }
                else {
                    textGroups.append([snapshot])
                }
            }
            for group in textGroups {
                if let selected = group.first(where: { $0.id == currentID }) {
                    choices.append(selected)
                }
                else if let latest = group.max(by: {
                    ($0.speakerLabelSource?.generatedAt ?? $0.savedAt)
                        < ($1.speakerLabelSource?.generatedAt ?? $1.savedAt)
                }) {
                    choices.append(latest)
                }
            }
        }
        return choices.sorted {
            $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt
        }
    }

    static func labelingChoices(_ revisions: [TranscriptRevision], current meeting: Meeting) -> [TranscriptRevision] {
        let values = snapshots(revisions, current: meeting)
        guard let selected = values.first(where: { $0.id == current(meeting).id }) else { return [] }
        return values.filter {
            ($0.source?.id ?? $0.id) == (selected.source?.id ?? selected.id)
                && sameText($0.segments, selected.segments)
        }.sorted {
            ($0.speakerLabelSource?.generatedAt ?? $0.savedAt) > ($1.speakerLabelSource?.generatedAt ?? $1.savedAt)
        }
    }

}

enum PrivateTranscriptFile {
    static func write(_ data: Data, name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = directory.appendingPathComponent(name)
        let previous = try? Data(contentsOf: target)
        let temporary = directory.appendingPathComponent(".transcript-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600])
        else {
            throw MeetingError.message("Couldn’t save the transcript revision.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary, options: .usingNewMetadataOnly)
        }
        else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        DataEventJournal.recordSavedFile(target, previous: previous, directory: directory)
    }
}

extension MeetingStore {
    func preserveTranscript(_ meeting: Meeting) -> Bool {
        guard libraryWritable else { return false }
        do {
            try TranscriptRevisions.preserve(meeting, at: directory(for: meeting.id))
            return true
        }
        catch {
            errorMessage = "Couldn’t save the previous transcript. The current transcript was kept."
            return false
        }
    }
    /// Restore only assignments from a compatible snapshot. Changed words,
    /// times, or source identity require a full transcript restore instead.
    @discardableResult
    func restoreSpeakerLabels(_ revision: TranscriptRevision, meetingID: UUID) -> Bool {
        guard var meeting = self.meeting(id: meetingID), libraryWritable, recordingID != meetingID,
            meeting.transcriptionAttempt == nil,
            !isJobRunning(.transcription, .meeting(meetingID)),
            !isJobRunning(.diarization, .meeting(meetingID)),
            !isJobRunning(.importAudio, .meeting(meetingID))
        else { return false }
        do {
            let saved = try TranscriptRevisions.read(at: directory(for: meetingID)).revisions
            guard
                let selected = TranscriptRevisions.labelingChoices(saved, current: meeting)
                    .first(where: { $0 == revision })
            else {
                errorMessage = "The transcript changed. These speaker labels can’t be restored to its current text."
                return false
            }
            guard preserveTranscript(meeting) else { return false }
            for index in meeting.transcript.indices {
                let row = selected.segments[index]
                meeting.transcript[index].speaker = row.speaker
                meeting.transcript[index].speakerID = row.speakerID
                meeting.transcript[index].sourcePlaceholder = row.sourcePlaceholder
                meeting.transcript[index].personID = row.personID.flatMap { id in
                    people.contains(where: { $0.id == id }) ? id : nil
                }
            }
            let currentSpeakers = meeting.speakers
            meeting.replaceSpeakers(
                selected.speakers.map { snapshot in
                    var speaker = snapshot
                    if let current = currentSpeakers.first(where: { $0.id == snapshot.id }),
                        current.manuallyAssigned == true
                    {
                        speaker = current
                    }
                    if let id = speaker.personID, !people.contains(where: { $0.id == id }) {
                        speaker.personID = nil
                        speaker.confirmed = false
                        speaker.confidence = nil
                    }
                    return speaker
                })
            meeting.transcriptSource = selected.source
            meeting.speakerLabelSource = selected.speakerLabelSource
            return updateMeeting(meeting)
        }
        catch {
            errorMessage = "Couldn’t read the saved speaker labels. The current labels were kept."
            return false
        }
    }

    func restoreTranscript(_ revision: TranscriptRevision, meetingID: UUID) {
        guard var meeting = self.meeting(id: meetingID), preserveTranscript(meeting) else { return }
        meeting.transcript = revision.segments
        meeting.speakerLabelSource = revision.speakerLabelSource
        meeting.transcriptSource =
            revision.source
            ?? TranscriptSource(
                id: revision.id, providerName: "Transcript", generatedAt: revision.savedAt)
        // A deleted person must not be recreated by restoring a transcript.
        meeting.replaceSpeakers(
            revision.speakers.map { speaker in
                var speaker = speaker
                if let id = speaker.personID, !people.contains(where: { $0.id == id }) {
                    speaker.personID = nil
                    speaker.confirmed = false
                    speaker.confidence = nil
                }
                return speaker
            })
        updateMeeting(meeting)
    }
}
