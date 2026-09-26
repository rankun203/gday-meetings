import Foundation

extension LiveTranscriptDraft {
    var hasUsableText: Bool {
        phrases.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension MeetingStore {
    /// Upgrade legacy live-only meetings once, outside view rendering. The marker
    /// prevents a later deliberate transcript clear from resurrecting the checkpoint.
    func recoverUnadoptedLiveTranscripts() {
        guard libraryWritable else { return }
        for meeting in meetings
        where !meeting.liveTranscriptAdopted && meeting.transcript.isEmpty
            && meeting.speakers.isEmpty && meeting.transcriptionAttempt == nil
        {
            do {
                if let draft = try LiveTranscriptDraft.read(at: directory(for: meeting.id), meetingID: meeting.id) {
                    _ = adoptLiveTranscript(draft)
                }
            }
            catch {
                errorMessage = "Couldn’t recover the live transcript for \(meeting.title). The saved file was kept."
            }
        }
    }

    /// Finalized live text joins the normal editable transcript. The checkpoint
    /// remains independent, including track sources, words, and coverage gaps.
    /// Automatic adoption only fills an empty, untouched transcript. Explicit
    /// recovery may replace it after the UI confirms, preserving the prior revision.
    @discardableResult
    func adoptLiveTranscript(_ draft: LiveTranscriptDraft, replacing: Bool = false) -> Bool {
        guard libraryWritable, draft.hasUsableText,
            var meeting = meetings.first(where: { $0.id == draft.meetingID }),
            meeting.transcriptionAttempt == nil,
            !isJobRunning(.transcription, .meeting(meeting.id))
        else { return false }
        if meeting.transcript == draft.segments && meeting.liveTranscriptAdopted { return true }
        guard replacing || (meeting.transcript.isEmpty && meeting.speakers.isEmpty) else { return false }
        guard preserveTranscript(meeting) else { return false }
        meeting.transcript = draft.segments
        meeting.liveTranscriptAdopted = true
        meeting.replaceSpeakers([])
        updateMeeting(meeting)
        return meetings.first(where: { $0.id == meeting.id })?.transcript == draft.segments
    }
}
