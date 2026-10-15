import Foundation

extension LiveTranscriptDraft {
    var hasUsableText: Bool {
        if let savedSegments { return !savedSegments.isEmpty }
        return !segments.isEmpty
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
    func recoverUnadoptedLiveTranscripts() async {
        guard libraryWritable else { return }
        for meeting in meetings {
            await recoverUnadoptedLiveTranscript(meeting)
        }
    }

    func recoverUnadoptedLiveTranscript(_ meeting: Meeting) async {
        guard libraryWritable, await recoverRecordingFinalization(id: meeting.id),
            let meeting = self.meeting(id: meeting.id)
        else { return }
        scheduleLiveSourcePlaceholderRecovery(meeting)
        guard libraryWritable, recordingID != meeting.id, !meeting.liveTranscriptAdopted,
            meeting.speakers.isEmpty, meeting.transcriptionAttempt == nil
        else { return }
        do {
            if let draft = try LiveTranscriptDraft.recover(at: directory(for: meeting.id), meetingID: meeting.id) {
                _ = await adoptLiveTranscript(draft)
            }
        }
        catch {
            errorMessage = "Couldn’t recover the live transcript for \(meeting.title). The saved file was kept."
        }
    }

    /// Publish the recording's source and speaker metadata without copying its
    /// already saved segments. Explicit replacement preserves a prior revision.
    @discardableResult
    func adoptLiveTranscript(_ draft: LiveTranscriptDraft, replacing: Bool = false) async -> Bool {
        await voiceLibrary.awaitLoaded()
        guard await ensureMeetingLoaded(id: draft.meetingID) else { return false }
        guard await flushCanonicalWrites() else { return false }
        let blockingTranscription: Bool
        do {
            let journal = managedTaskJournal
            let id = draft.meetingID
            blockingTranscription = try await managedTaskIO.perform {
                try journal.query(
                    where: "meeting=" + ManagedTaskIndex.literal(id.uuidString)
                        + " AND kind='transcription' AND state IN ('queued','running')", limit: Int.max
                )
                .contains { $0.pipelineID == nil || $0.state == .running }
            }
        }
        catch {
            errorMessage = "Couldn’t check the recording’s transcription tasks. \(error.localizedDescription)"
            return false
        }
        guard libraryWritable, draft.hasUsableText,
            var meeting = self.meeting(id: draft.meetingID),
            meeting.transcriptionAttempt == nil,
            !blockingTranscription,
            !backgroundJobs.contains(where: { $0.key.kind == .transcription && $0.meetingID == meeting.id })
        else { return false }
        let adoptionBaseline = meeting
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
            meeting: meeting, directory: directory(for: meeting.id))
        meeting = voiceLibrary.applyingDecisions(to: meeting)
        if recordingID == meeting.id {
            let adopted = meeting
            return await enqueueCanonical {
                guard let index = self.meetings.firstIndex(where: { $0.id == adopted.id }) else { return false }
                guard
                    let merged = try? RecordingMeetingMerge.merge(
                        baseline: adoptionBaseline, proposed: adopted, disk: self.meetings[index])
                else { return false }
                self.meetings[index] = merged
                return await self.performCanonicalSave(meetingID: adopted.id, commitVoice: true)
            }
        }
        return await updateMeeting(meeting)
    }
}
