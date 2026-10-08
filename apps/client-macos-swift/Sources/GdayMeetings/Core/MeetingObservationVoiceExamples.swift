import Foundation

extension MeetingStore {
    /// The callback is a complete representative snapshot, not another inference
    /// window to append. Raw evidence remains in the recording's durable journal.
    @discardableResult
    func recordObservationVoiceExamples(
        meetingID: UUID, representatives: [LiveObservationReviewAssignment]
    ) async -> Bool {
        guard await voiceLibrary.awaitReady(), !Task.isCancelled, libraryWritable, recordingID == meetingID
        else { return false }
        // A human association can have a staged voice document while its canonical
        // save runs off actor. Queue this snapshot behind that save instead of
        // dropping the final voice evidence when the library is temporarily busy.
        return await enqueueCanonical { [self] in
            guard libraryWritable, recordingID == meetingID, let meeting = meeting(id: meetingID) else { return false }
            var examples: [VoiceExample] = []
            for representative in representatives {
                let sample = representative.sample
                guard let speakerID = representative.meetingSpeakerID else { continue }
                guard sample.embedding.isValid else {
                    errorMessage = "Couldn’t update speaker review examples: invalid voice evidence."
                    return false
                }
                let files = meeting.audioFiles.filter {
                    LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == sample.source
                }
                guard files.count == 1 else {
                    errorMessage = "Couldn’t locate the recording source for a speaker review example."
                    return false
                }
                examples.append(
                    VoiceExample(
                        id: MeetingSpeakerConsolidation.identity(
                            meetingID: meetingID, clusterID: sample.id, method: "live-observation-evidence-v1"),
                        meetingID: meetingID, speakerID: speakerID, source: sample.source,
                        audioFile: files[0], start: sample.start, end: sample.end,
                        embeddings: [sample.embedding], groupID: speakerID, origin: .liveSpeech,
                        observationID: sample.id))
            }
            guard
                await voiceLibrary.reconcileObservationExamplesForCapture(
                    meetingID: meetingID, representatives: examples)
            else {
                errorMessage = voiceLibrary.errorMessage ?? "Couldn’t update speaker review examples."
                return false
            }
            if settings.recognizeLiveSpeakers { voiceLibrary.scheduleReviewedPeopleSuggestions(from: people) }
            return true
        }
    }
}
