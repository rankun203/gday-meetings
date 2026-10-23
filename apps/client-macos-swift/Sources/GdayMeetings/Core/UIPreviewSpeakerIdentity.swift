import Foundation

extension UIPreview {
    /// Synthetic voice vectors and silent audio exercise review without loading a model.
    @MainActor static func seedSpeakerIdentityReview(store: MeetingStore, meeting: Meeting)
        async throws
    {
        if UIPreviewPerformanceFixtures.flag(
            "--synthetic-readable-transcript", infoKey: "GdaySyntheticReadableTranscript")
        {
            try await seedReadableTranscriptPresentation(store: store, meeting: meeting)
            return
        }
        if UIPreviewPerformanceFixtures.flag(
            "--synthetic-transcript-associations", infoKey: "GdaySyntheticTranscriptAssociations")
        {
            try await seedTranscriptAssociationPresentation(store: store, meeting: meeting)
            return
        }
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

extension UIPreview {
    /// Presentation fixture uses production projection; no capture or model inference.
    @MainActor static func seedTranscriptAssociationPresentation(store: MeetingStore, meeting: Meeting)
        async throws
    {
        guard let firstPerson = store.people.first?.id, let secondPerson = store.people.dropFirst().first?.id else {
            throw ServiceError("The transcript preview needs two synthetic people.")
        }
        // Ordinary Preview seeds reviewed examples first. Drain their matching
        // work before replacing the speaker set, then provide real synthetic
        // representations so later matching reproduces the same attribution.
        await store.voiceLibrary.awaitLoaded()
        await store.flushVoiceAssignmentRefresh()
        var value = store.meeting(id: meeting.id) ?? meeting
        let folder = store.directory(for: value.id)
        let audioFile = "microphone.wav"
        let revision = VoiceLibraryStore.revision(url: folder.appendingPathComponent(audioFile))
        let manual = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic Speaker Analysis",
            personID: firstPerson, manuallyAssigned: true)
        let automatic = MeetingSpeaker(
            label: "mic_02", track: "microphone", providerName: "Synthetic Speaker Analysis")
        let tentative = MeetingSpeaker(
            label: "mic_03", track: "microphone", providerName: "Synthetic Speaker Analysis")
        value.replaceSpeakers([manual, automatic, tentative])
        value.transcript = [
            .init(
                start: 1, end: 3, speaker: manual.label, text: "This person was assigned manually.",
                speakerID: manual.id, source: .microphone),
            .init(
                start: 5, end: 8, speaker: automatic.label, text: "This speaker was matched automatically.",
                speakerID: automatic.id, source: .microphone),
            .init(
                start: 10, end: 13, speaker: tentative.label, text: "This speaker has a tentative person match.",
                speakerID: tentative.id, source: .microphone),
            .init(
                start: 15, end: 16, speaker: automatic.label, text: "This passage still has an uncertain voice.",
                speakerID: automatic.id, source: .microphone, associationUncertain: true),
            .init(
                start: 17, end: 18, speaker: "mic", text: "This passage retains its audio source.",
                source: .microphone, sourcePlaceholder: true),
        ]
        value.transcriptSource = .init(
            id: UUID(), providerName: "Synthetic Transcription", generatedAt: value.createdAt)
        value.speakerLabelSource = nil
        guard await store.updateMeeting(value) else {
            throw ServiceError("Couldn’t save the transcript preview.")
        }
        let type = EmbeddingType(
            modelID: "synthetic-transcript-preview", revision: "one", compatibilityVersion: "one",
            dimension: 3, normalization: "unitL2")
        func embedding(_ values: [Double]) -> TypedVoiceEmbedding {
            .init(type: type, values: values, provenance: "Synthetic transcript presentation")
        }
        let references = [
            VoiceExample(
                meetingID: value.id, speakerID: UUID(), source: "microphone", audioFile: audioFile,
                audioRevision: revision, start: 21, end: 24, personID: firstPerson,
                review: .confirmed, embeddings: [embedding([1, 0, 0])]),
            VoiceExample(
                meetingID: value.id, speakerID: UUID(), source: "microphone", audioFile: audioFile,
                audioRevision: revision, start: 25, end: 28, personID: secondPerson,
                review: .confirmed, embeddings: [embedding([0, 1, 0])]),
        ]
        let candidates = [
            VoiceExample(
                meetingID: value.id, speakerID: automatic.id, source: "microphone", audioFile: audioFile,
                audioRevision: revision, start: 5, end: 8,
                embeddings: [embedding([0, 0.94, sqrt(1 - 0.94 * 0.94)])], groupID: automatic.id),
            VoiceExample(
                meetingID: value.id, speakerID: tentative.id, source: "microphone", audioFile: audioFile,
                audioRevision: revision, start: 10, end: 13,
                embeddings: [embedding([0.6, 0, sqrt(1 - 0.6 * 0.6)])], groupID: tentative.id),
        ]
        guard store.voiceLibrary.upsert(references + candidates) else {
            throw ServiceError("Couldn’t save the transcript match preview.")
        }
        await store.flushVoiceAssignmentRefresh()
        // Matching publication schedules projection independently. Make that
        // lifecycle boundary explicit before validating or saving the checkpoint.
        await store.refreshVoiceAssignments(meetingIDs: [value.id], recomputeSuggestions: false)
        let projected = store.meeting(id: value.id)
        guard
            projected?.speakers.contains(where: {
                $0.id == automatic.id && $0.personID == secondPerson
                    && $0.voiceReviewOrigin?.transcriptAssociationTier == .automatic
            }) == true,
            projected?.speakers.contains(where: {
                $0.id == tentative.id && $0.personID == firstPerson
                    && $0.voiceReviewOrigin?.transcriptAssociationTier == .tentative
            }) == true
        else {
            throw ServiceError("Couldn’t prepare the transcript match preview.")
        }
        var checkpoint = LiveTranscriptDraft(meetingID: value.id, locale: "en-AU")
        checkpoint.savedSegments = store.meeting(id: value.id)?.transcript ?? value.transcript
        checkpoint.complete = true
        try checkpoint.save(at: folder)
    }
}

extension UIPreview {
    @MainActor static func seedReadableTranscriptPresentation(store: MeetingStore, meeting: Meeting) async throws {
        try await seedTranscriptAssociationPresentation(store: store, meeting: meeting)
        guard var value = store.meeting(id: meeting.id),
            let automatic = value.speakers.first(where: { $0.label == "mic_02" }),
            let tentative = value.speakers.first(where: { $0.label == "mic_03" })
        else { throw ServiceError("Couldn’t prepare the readable transcript preview.") }
        var rows: [TranscriptSegment] = []
        var time = 1.0
        func append(_ parts: [(String, MeetingSpeaker?)]) {
            let original = UUID()
            var offset = 0
            for (text, speaker) in parts {
                rows.append(
                    .init(
                        start: time, end: time + 0.5, speaker: speaker?.label ?? "mic", text: text,
                        speakerID: speaker?.id, source: .microphone, sourcePlaceholder: speaker == nil,
                        timing: .init(
                            text: text,
                            spans: [
                                .init(
                                    range: .init(location: 0, length: text.utf16.count), start: time, end: time + 0.5,
                                    granularity: .run)
                            ]),
                        sourceSpans: [
                            .init(rowID: original, range: .init(location: offset, length: text.utf16.count), text: text)
                        ]))
                offset += text.utf16.count
                time += 0.5
            }
            time += 1
        }
        append([("The schedule is ready", automatic), (", ", nil), ("and the notes are saved", automatic), (".", nil)])
        append([("The next speaker", automatic), (" has an update.", tentative)])
        append([("An ", nil), ("unlabeled ", nil), ("paragraph.", nil)])
        value.transcript = rows
        guard await store.updateMeeting(value) else {
            throw ServiceError("Couldn’t save the readable transcript preview.")
        }
        var checkpoint = LiveTranscriptDraft(meetingID: value.id, locale: "en-AU")
        checkpoint.savedSegments = rows
        checkpoint.complete = true
        try checkpoint.save(at: store.directory(for: value.id))
    }
}
