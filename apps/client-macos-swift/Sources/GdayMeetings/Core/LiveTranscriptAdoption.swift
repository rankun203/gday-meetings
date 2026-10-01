import Foundation

extension LiveTranscriptDraft {
    var hasUsableText: Bool {
        !segments.isEmpty
    }
}

extension MeetingStore {
    func liveTranscriptSource(_ draft: LiveTranscriptDraft, meeting: Meeting) -> TranscriptSource {
        let file = directory(for: meeting.id).appendingPathComponent("live-transcript.json")
        let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return TranscriptSource(
            id: draft.phrases.sorted(by: LiveTranscriptPhrase.ordered).first?.session ?? meeting.id,
            providerName: draft.provider, generatedAt: saved ?? meeting.createdAt)
    }

    /// Upgrade legacy live-only meetings once, outside view rendering. The marker
    /// prevents a later deliberate transcript clear from resurrecting the checkpoint.
    func recoverUnadoptedLiveTranscripts() {
        guard libraryWritable else { return }
        for meeting in meetings {
            recoverUnadoptedLiveTranscript(meeting)
        }
    }

    func recoverUnadoptedLiveTranscript(_ meeting: Meeting) {
        guard libraryWritable, !meeting.liveTranscriptAdopted, meeting.transcript.isEmpty,
            meeting.speakers.isEmpty, meeting.transcriptionAttempt == nil
        else { return }
        do {
            if let draft = try LiveTranscriptDraft.read(at: directory(for: meeting.id), meetingID: meeting.id) {
                _ = adoptLiveTranscript(draft)
            }
        }
        catch {
            errorMessage = "Couldn’t recover the live transcript for \(meeting.title). The saved file was kept."
        }
    }

    /// Finalized live text joins the normal editable transcript. The checkpoint
    /// remains independent, including track sources, words, and coverage gaps.
    /// Automatic adoption only fills an empty, untouched transcript. Explicit
    /// recovery may replace it after the UI confirms, preserving the prior revision.
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
        guard replacing || (meeting.transcript.isEmpty && meeting.speakers.isEmpty) else { return false }
        guard preserveTranscript(meeting) else { return false }
        meeting.transcript = draft.segments
        meeting.transcriptSource = source
        meeting.liveTranscriptAdopted = true
        meeting.replaceSpeakers(speakers)
        return updateMeeting(meeting)
    }
}
