import SwiftUI

/// Saved transcript actions stay outside the text viewport. Old live checkpoints
/// remain readable, and the first edit adopts them through the same safe store API.
struct MeetingTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    @ViewState private var draft: LiveTranscriptDraft?
    @ViewState private var revisions: [TranscriptRevision] = []
    @ViewState private var failure: String?

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }
    private var usesCheckpoint: Bool {
        meeting?.transcript.isEmpty == true && meeting?.liveTranscriptAdopted != true && draft?.phrases.isEmpty == false
    }
    private var segments: [TranscriptSegment] { usesCheckpoint ? draft?.segments ?? [] : meeting?.transcript ?? [] }
    private var canRestore: Bool {
        store.libraryWritable && store.recordingID != meetingID && meeting?.transcriptionAttempt == nil
            && !store.isJobRunning(.transcription, .meeting(meetingID))
            && !store.isJobRunning(.importAudio, .meeting(meetingID))
    }
    private var showsLiveText: Bool {
        guard let draft, !draft.phrases.isEmpty else { return false }
        return usesCheckpoint || Set(segments.map(\.id)) == Set(draft.phrases.map(\.id))
    }
    var body: some View {
        if let meeting {
            let displayedSegments = segments
            let showsSpeakers =
                !usesCheckpoint && displayedSegments.contains { !$0.speaker.isEmpty || $0.speakerID != nil }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        TranscriptionActionButton(meeting: meeting, hasTranscript: !segments.isEmpty)
                        Spacer(minLength: 8)
                        historyMenu
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TranscriptionActionButton(meeting: meeting, hasTranscript: !segments.isEmpty)
                        historyMenu
                    }
                }
                if showsLiveText {
                    Text(
                        draft?.complete == true
                            ? "Live transcript · This Mac" : "Live transcript · This Mac · Some audio may be missing."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if segments.isEmpty {
                            ContentUnavailableView(
                                "No Transcript Yet", systemImage: "text.bubble",
                                description: Text("Transcribe the recording to create a transcript.")
                            )
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(displayedSegments) { segment in
                            TranscriptRow(
                                start: segment.start,
                                speaker: usesCheckpoint
                                    ? ""
                                    : meeting.speakerName(
                                        for: segment, people: store.people, includesSuggestion: false),
                                showsSpeakerColumn: showsSpeakers,
                                seek: canPlay(meeting) ? { seek(segment.start, meeting: meeting) } : nil
                            ) {
                                TextField(
                                    "Transcript",
                                    text: Binding(
                                        get: {
                                            String(
                                                (segments.first { $0.id == segment.id }?.text ?? "")
                                                    .drop(while: { $0.isWhitespace }))
                                        },
                                        set: { updateSegment(segment.id, text: $0) }), axis: .vertical
                                )
                                .textFieldStyle(.plain)
                                .disabled(usesCheckpoint && !canRestore)
                            }
                        }
                        if !usesCheckpoint && !meeting.speakers.isEmpty {
                            MeetingSpeakersView(meetingID: meetingID)
                        }
                    }.padding(4)
                }
            }
            .task(id: meetingID) { loadHistory() }
            .onChange(of: meeting.transcript) { _, _ in loadHistory() }
        }
    }
    @ViewBuilder private var historyMenu: some View {
        if draft?.phrases.isEmpty == false || !revisions.isEmpty {
            Menu("Transcript History") {
                if let draft, !draft.phrases.isEmpty {
                    Button("Restore Live Transcript · This Mac") {
                        _ = store.adoptLiveTranscript(draft, replacing: true)
                        loadHistory()
                    }
                }
                if draft?.phrases.isEmpty == false && !revisions.isEmpty { Divider() }
                ForEach(revisions.reversed()) { revision in
                    Button("\(revision.title) · \(revision.savedAt.formatted(date: .abbreviated, time: .standard))") {
                        store.restoreTranscript(revision, meetingID: meetingID)
                        loadHistory()
                    }
                }
            }.disabled(!canRestore)
        }
    }
    private func canPlay(_ meeting: Meeting) -> Bool {
        !playback.isPlaybackBlocked && !store.audioURLs(for: meeting).isEmpty
    }
    private func seek(_ time: Double, meeting: Meeting) {
        playback.play(meeting: meeting, files: store.audioURLs(for: meeting), at: time)
    }
    private func updateSegment(_ id: UUID, text: String) {
        if usesCheckpoint {
            guard let draft, store.adoptLiveTranscript(draft) else { return }
        }
        guard var meeting = self.meeting, let index = meeting.transcript.firstIndex(where: { $0.id == id }) else {
            return
        }
        meeting.transcript[index].text = text
        store.updateMeeting(meeting)
    }
    private func loadHistory() {
        draft = nil
        revisions = []
        failure = nil
        do {
            draft = try LiveTranscriptDraft.read(at: store.directory(for: meetingID), meetingID: meetingID)
            revisions = try TranscriptRevisions.read(at: store.directory(for: meetingID)).revisions
        }
        catch { failure = error.localizedDescription }
    }
}
