import Foundation

extension UIPreview {
    /// Real review screens with references, empty people, and more than one unnamed
    /// group expose navigation failures that a single candidate cannot exercise.
    @MainActor static func seedPeopleReviewSession(store: MeetingStore, meeting: Meeting, personID: UUID)
        async throws
    {
        guard UIPreviewPerformanceFixtures.flag("--synthetic-people-review", infoKey: "GdaySyntheticPeopleReview")
        else { return }
        var transcriptMeeting = meeting
        for index in transcriptMeeting.transcript.indices {
            transcriptMeeting.transcript[index].source =
                transcriptMeeting.transcript[index].speakerID == meeting.speakers[2].id ? .microphone : .system
        }
        let text = "Please check the revised schedule."
        let words: [LiveTranscriptWord] = [
            .init(text: "Please", start: 16, end: 17),
            .init(text: "check", start: 17, end: 18),
            .init(text: "the", start: 18, end: 18.5),
            .init(text: "revised", start: 18.5, end: 20),
            .init(text: "schedule.", start: 20, end: 21),
        ]
        transcriptMeeting.transcript.append(
            TranscriptSegment(
                start: 16, end: 21, text: text, source: .system,
                timing: .fromWords(text: text, words: words, granularity: .word)))
        transcriptMeeting.transcript.append(
            TranscriptSegment(
                start: 16, end: 21, text: "This other track must not appear in the system excerpt.", source: .microphone
            ))
        guard await store.updateMeeting(transcriptMeeting) else {
            throw ServiceError("Couldn’t save the review transcript preview.")
        }
        _ = await store.addPerson(name: "Taylor Lee")
        let file = "system.wav"
        let revision = VoiceLibraryStore.revision(url: store.directory(for: meeting.id).appendingPathComponent(file))
        let referenceVector = TypedVoiceEmbedding(
            type: .community1, values: [1, 0] + [Double](repeating: 0, count: 254),
            provenance: "Synthetic review reference")
        let reference = VoiceExample(
            meetingID: meeting.id, speakerID: meeting.speakers[0].id, source: "system",
            audioFile: file, audioRevision: revision, start: 34, end: 38,
            personID: personID, review: .confirmed, embeddings: [referenceVector])
        // Keep one useful tentative voice proposal after selective review drops
        // clear automatic matches. These vectors exercise layout, not accuracy.
        let candidates = store.voiceLibrary.examples.filter {
            $0.suggestedPersonID == personID && $0.range != nil && !$0.excluded
        }.enumerated().map { index, original in
            var example = original
            let similarity = index.isMultiple(of: 2) ? 0.79 : 0.72
            example.embeddings = [
                TypedVoiceEmbedding(
                    type: .community1,
                    values: [similarity, sqrt(1 - similarity * similarity)] + [Double](repeating: 0, count: 254),
                    provenance: "Synthetic tentative review proposal")
            ]
            return example
        }
        guard store.voiceLibrary.upsert([reference] + candidates) else {
            throw ServiceError("Couldn’t save the reference sample preview.")
        }
        guard let other = store.meetings.first(where: { $0.id != meeting.id }) else { return }
        let otherFile = "microphone.wav"
        let otherRevision = VoiceLibraryStore.revision(
            url: store.directory(for: other.id).appendingPathComponent(otherFile))
        let speakerID = UUID()
        let groupID = UUID()
        var examples = [
            VoiceExample(
                meetingID: other.id, speakerID: speakerID, source: "microphone",
                audioFile: otherFile, audioRevision: otherRevision, start: 12, end: 18, groupID: groupID),
            VoiceExample(
                meetingID: other.id, speakerID: speakerID, source: "microphone",
                audioFile: otherFile, audioRevision: otherRevision, start: 22, end: 27, groupID: groupID),
        ]
        var duplicate = examples[0]
        duplicate.id = UUID()
        duplicate.speakerID = UUID()
        examples.append(duplicate)
        guard store.voiceLibrary.upsert(examples) else {
            throw ServiceError("Couldn’t save the identification session preview.")
        }
        await store.flushVoiceAssignmentRefresh()
    }
    /// Opt-in scale fixture exercises production list reuse with independent candidates.
    @MainActor static func seedLargePeopleReview(store: MeetingStore, meeting: Meeting) throws {
        guard
            UIPreviewPerformanceFixtures.flag(
                "--synthetic-people-review-large", infoKey: "GdaySyntheticPeopleReviewLarge")
        else { return }
        let file = "system.wav"
        let revision = VoiceLibraryStore.revision(url: store.directory(for: meeting.id).appendingPathComponent(file))
        let examples = (0..<1000).map { index in
            // Excerpts overlap but differ enough to retain separate exact-audio keys.
            VoiceExample(
                meetingID: meeting.id, speakerID: UUID(), source: "system",
                audioFile: file, audioRevision: revision, start: Double(index) / 100, end: Double(index) / 100 + 3,
                groupID: UUID())
        }
        guard store.voiceLibrary.upsert(examples) else { throw ServiceError("Couldn’t save the large review preview.") }
    }

}
