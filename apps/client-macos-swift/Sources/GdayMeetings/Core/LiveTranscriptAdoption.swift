import Foundation

extension LiveTranscriptDraft {
    var hasUsableText: Bool {
        !segments.isEmpty
    }
}

extension MeetingStore {
    func liveTranscriptSource(_ draft: LiveTranscriptDraft, meeting: Meeting) -> TranscriptSource {
        let file = directory(for: meeting.id).appendingPathComponent(LiveTranscriptProjection.checkpointName)
        let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return TranscriptSource(
            id: draft.phrases.sorted(by: LiveTranscriptPhrase.ordered).first?.session ?? meeting.id,
            providerName: draft.provider, generatedAt: saved ?? meeting.createdAt)
    }

    /// Publish speaker and source metadata after an interrupted recording, using
    /// the same canonical segments that were already loaded from disk.
    func recoverUnadoptedLiveTranscripts() {
        guard libraryWritable else { return }
        for meeting in meetings {
            recoverUnadoptedLiveTranscript(meeting)
        }
    }

    func recoverUnadoptedLiveTranscript(_ meeting: Meeting) {
        recoverLiveSourcePlaceholders(meeting)
        guard libraryWritable, recordingID != meeting.id, !meeting.liveTranscriptAdopted,
            meeting.speakers.isEmpty, meeting.transcriptionAttempt == nil
        else { return }
        do {
            if let draft = try LiveTranscriptDraft.recover(at: directory(for: meeting.id), meetingID: meeting.id) {
                _ = adoptLiveTranscript(draft)
            }
        }
        catch {
            errorMessage = "Couldn’t recover the live transcript for \(meeting.title). The saved file was kept."
        }
    }

    /// Source labels overlap detected labels. Recover their meaning only from
    /// the checkpoint's matching identities, never from spelling.
    private func recoverLiveSourcePlaceholders(_ meeting: Meeting) {
        guard libraryWritable, meeting.liveTranscriptAdopted,
            meeting.speakers.contains(where: { $0.sourcePlaceholder == nil }),
            let draft = try? LiveTranscriptDraft.read(at: directory(for: meeting.id), meetingID: meeting.id),
            meeting.transcriptSource?.id == liveTranscriptSource(draft, meeting: meeting).id
        else { return }
        let sources = Dictionary(
            uniqueKeysWithValues: draft.speakers.compactMap { speaker in
                speaker.sourcePlaceholder.map { (speaker.id, $0) }
            })
        var updated = meeting
        for index in updated.speakers.indices {
            let speaker = updated.speakers[index]
            if speaker.sourcePlaceholder == nil, let source = sources[speaker.id] {
                updated.speakers[index].sourcePlaceholder = source
            }
        }
        if updated.speakers != meeting.speakers { _ = updateMeeting(updated) }
    }

    /// Publish the recording's source and speaker metadata without copying its
    /// already saved segments. Explicit replacement preserves a prior revision.
    @discardableResult
    func adoptLiveTranscript(_ draft: LiveTranscriptDraft, replacing: Bool = false) -> Bool {
        guard libraryWritable, draft.hasUsableText,
            var meeting = self.meeting(id: draft.meetingID),
            meeting.transcriptionAttempt == nil,
            !isJobRunning(.transcription, .meeting(meeting.id))
        else { return false }
        let source = liveTranscriptSource(draft, meeting: meeting)
        var speakers = draft.speakers
        for index in speakers.indices where !people.contains(where: { $0.id == speakers[index].personID }) {
            speakers[index].personID = nil
            speakers[index].confirmed = false
        }
        if meeting.transcript == draft.segments && meeting.speakers == speakers && meeting.liveTranscriptAdopted
            && meeting.transcriptSource?.id == source.id
        {
            return true
        }
        guard
            replacing || (meeting.transcript.isEmpty && meeting.speakers.isEmpty)
                || meeting.transcript == draft.segments
        else { return false }
        if !meeting.transcript.isEmpty
            && (meeting.transcript != draft.segments
                || meeting.transcriptSource.map { $0.id != source.id } == true)
        {
            guard preserveTranscript(meeting) else { return false }
        }
        meeting.transcript = draft.segments
        meeting.transcriptSource = source
        meeting.speakerLabelSource = nil
        meeting.liveTranscriptAdopted = true
        meeting.replaceSpeakers(speakers)
        _ = voiceLibrary.ingest(
            meeting: meeting, directory: directory(for: meeting.id),
            finalizeLive: recordingID == meeting.id && isFinalizingRecording)
        meeting = voiceLibrary.applyingDecisions(to: meeting)
        return updateMeeting(meeting)
    }
}
