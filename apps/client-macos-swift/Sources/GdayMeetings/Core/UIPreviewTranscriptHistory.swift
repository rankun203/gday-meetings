import Foundation

extension UIPreview {
    /// Reproduce old label-only snapshots without running a model or reading a library.
    @MainActor static func seedTranscriptLabelingHistory(
        store: MeetingStore, meeting: Meeting, live: LiveTranscriptDraft
    ) async throws {
        guard
            ProcessInfo.processInfo.arguments.contains("--synthetic-labeling-history")
                || Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticLabelingHistory") as? Bool == true
        else { return }
        var original = meeting
        original.transcriptSource = store.liveTranscriptSource(live, meeting: meeting)
        original.liveTranscriptAdopted = true
        try TranscriptRevisions.preserve(original, at: store.directory(for: meeting.id))
        var labeled = original
        let result = LocalDiarizationResult(
            modelRevision: "synthetic-labeling-v1", ranges: [], speakers: labeled.speakers)
        labeled.transcriptSource = .init(
            id: result.id, providerName: "Community-1 Speaker Labeling", generatedAt: result.generatedAt)
        try PrivateTranscriptFile.write(
            JSONEncoder().encode(result), name: "speaker-labels-\(result.id).json", at: store.directory(for: meeting.id)
        )
        _ = await store.updateMeeting(labeled)
    }
}
