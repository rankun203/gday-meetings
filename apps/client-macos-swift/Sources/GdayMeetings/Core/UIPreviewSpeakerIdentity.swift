import Foundation

extension UIPreview {
    /// Synthetic voice vectors and silent audio exercise review without loading a model.
    @MainActor static func seedSpeakerIdentityReview(store: MeetingStore, meeting: Meeting)
        async throws
    {
        guard
            UIPreviewPerformanceFixtures.flag(
                "--synthetic-speaker-identity", infoKey: "GdaySyntheticSpeakerIdentity")
        else { return }
        var value = store.meeting(id: meeting.id) ?? meeting
        let source = "microphone"
        let file = "microphone.wav"
        let folder = store.directory(for: value.id)
        let person = store.people.first?.id
        let voice = TypedVoiceEmbedding(
            type: .community1SpeechSpan, values: [1] + [Double](repeating: 0, count: 255),
            provenance: "Synthetic review fixture")
        let fragments = [SpeakerEvidenceSpan(start: 8, end: 9), .init(start: 13, end: 14)]
        let fragmentVoice = TypedVoiceEmbedding(
            type: .community1SpeechSpan, values: [0, 1] + [Double](repeating: 0, count: 254),
            provenance: "saved-example-clean-fragments-v1")
        let revision = VoiceLibraryStore.revision(url: folder.appendingPathComponent(file))
        let first = MeetingSpeaker(
            label: "Speaker 1", track: source, providerName: "Synthetic Voice Clustering",
            voiceEmbedding: voice, personID: person, confidence: 0.96,
            voiceSampleRange: .init(audioFile: file, source: source, start: 1, end: 4),
            voiceSampleRevision: revision)
        let second = MeetingSpeaker(
            label: "Speaker 2", track: source, providerName: "Synthetic Voice Clustering",
            voiceEmbedding: fragmentVoice,
            voiceSampleRange: .init(audioFile: file, source: source, start: 8, end: 14, spans: fragments),
            voiceSampleRevision: revision)
        let withoutEvidence = MeetingSpeaker(
            label: "Speaker 3", track: source, providerName: "Synthetic Voice Clustering")
        value.replaceSpeakers([first, second, withoutEvidence])
        value.transcript = [
            .init(
                start: 1, end: 4, speaker: first.label, text: "The review starts with the schedule.",
                speakerID: first.id, source: .microphone),
            .init(
                start: 5, end: 6, speaker: first.label, text: "This short reply needs a speaker review.",
                speakerID: first.id, source: .microphone, associationUncertain: true),
            .init(
                start: 8, end: 9, speaker: second.label, text: "I have an update.",
                speakerID: second.id, source: .microphone),
            .init(
                start: 13, end: 14, speaker: second.label, text: "The notes are ready.",
                speakerID: second.id, source: .microphone),
            .init(
                start: 18, end: 19, speaker: withoutEvidence.label, text: "Thanks for the update.",
                speakerID: withoutEvidence.id, source: .microphone, associationUncertain: true),
        ]
        value.transcriptSource = .init(
            id: UUID(), providerName: "Synthetic Live Transcription", generatedAt: value.createdAt)
        value.speakerLabelSource = nil
        guard await store.updateMeeting(value) else {
            throw ServiceError("Couldn’t save the speaker review preview.")
        }
        let examples = [
            VoiceExample(
                meetingID: value.id, speakerID: first.id, source: source, audioFile: file,
                audioRevision: revision, start: 1, end: 4, suggestedPersonID: person,
                review: .suggested, embeddings: [voice], groupID: first.id),
            VoiceExample(
                meetingID: value.id, speakerID: second.id, source: source, audioFile: file,
                audioRevision: revision, start: 8, end: 14, review: .unassigned,
                embeddings: [fragmentVoice], groupID: second.id, spans: fragments),
        ]
        guard store.voiceLibrary.upsert(examples) else {
            throw ServiceError("Couldn’t save synthetic voice examples.")
        }
        await store.flushVoiceAssignmentRefresh()
        var checkpoint = LiveTranscriptDraft(meetingID: value.id, locale: "en-AU")
        checkpoint.savedSegments = value.transcript
        checkpoint.complete = true
        try checkpoint.save(at: folder)
    }
}
