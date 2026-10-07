import Foundation

extension UIPreview {
    /// Retained evidence is synthetic; this fixture never records audio or loads a model.
    @MainActor static func seedSpeakerConsolidation(store: MeetingStore, meeting: Meeting) async throws {
        guard
            UIPreviewPerformanceFixtures.flag(
                "--synthetic-speaker-consolidation", infoKey: "GdaySyntheticSpeakerConsolidation")
        else { return }
        var value = store.meeting(id: meeting.id) ?? meeting
        let type = EmbeddingType.community1SpeechSpan
        let firstVoice = TypedVoiceEmbedding(type: type, values: [1] + [Double](repeating: 0, count: 255))
        let secondVoice = TypedVoiceEmbedding(type: type, values: [0, 1] + [Double](repeating: 0, count: 254))
        let first = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic Live Speaker Labeling",
            voiceEmbedding: firstVoice)
        let second = MeetingSpeaker(
            label: "mic_02", track: "microphone", providerName: "Synthetic Live Speaker Labeling",
            voiceEmbedding: firstVoice)
        let renewed = MeetingSpeaker(
            label: "mic_04", track: "microphone", providerName: "Synthetic Live Speaker Labeling",
            voiceEmbedding: secondVoice)
        let withoutSample = MeetingSpeaker(
            label: "mic_03", track: "microphone", providerName: "Synthetic Live Speaker Labeling")
        value.replaceSpeakers([first, second, renewed, withoutSample])
        value.transcript = [
            .init(
                start: 1, end: 4, speaker: first.label, text: "Let’s review the schedule.",
                speakerID: first.id, source: .microphone),
            .init(
                start: 8, end: 11, speaker: second.label, text: "I have one more update about the schedule.",
                speakerID: second.id, source: .microphone),
            .init(
                start: 16, end: 19, speaker: renewed.label, text: "I’ll check the notes after this call.",
                speakerID: renewed.id, source: .microphone),
            .init(
                start: 24, end: 27, speaker: withoutSample.label, text: "Thanks for the update.",
                speakerID: withoutSample.id, source: .microphone),
        ]
        value.transcriptSource = .init(
            id: UUID(), providerName: "Synthetic Live Transcription", generatedAt: value.createdAt)
        value.speakerLabelSource = nil
        let samples: [SpeakerEvidenceSample] = [
            .init(
                id: "preview-a", source: "microphone", localSpeakerID: first.id.uuidString,
                start: 1, end: 4, embedding: firstVoice),
            .init(
                id: "preview-b", source: "microphone", localSpeakerID: second.id.uuidString,
                start: 8, end: 11, embedding: firstVoice),
            .init(
                id: "preview-c", source: "microphone", localSpeakerID: renewed.id.uuidString,
                start: 16, end: 19, embedding: secondVoice),
        ]
        let folder = store.directory(for: value.id)
        let journal = SpeakerEvidenceStore(directory: folder)
        for sample in samples { try await journal.append(sample) }
        for (index, rows) in [Array(value.transcript.prefix(2)), Array(value.transcript.suffix(2))].enumerated() {
            try await journal.append(
                rows.map {
                    .init(source: "microphone", localSpeakerID: $0.speakerID!.uuidString, start: $0.start, end: $0.end)
                },
                window: .init(
                    generation: "preview-window-\(index)", source: "microphone",
                    localSpeakerIDs: rows.compactMap { $0.speakerID?.uuidString },
                    publicationStart: index == 0 ? 0 : 12, observedEnd: index == 0 ? 12 : 28,
                    policyRevision: SpeakerEvidenceWindow.protectedPolicy))
        }
        try await journal.finish()
        try SpeakerEvidenceInputReceipt.seal(directory: folder, files: store.audioURLs(for: value))
        guard await store.updateMeeting(value) else {
            throw ServiceError("Couldn’t save the speaker consolidation preview.")
        }
        var checkpoint = LiveTranscriptDraft(meetingID: value.id, locale: "en-AU")
        checkpoint.savedSegments = value.transcript
        checkpoint.complete = true
        try checkpoint.save(at: folder)
    }
}
