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
    @ViewState private var displayRows: [TranscriptDisplayRow] = []
    @ViewState private var displayGeneration = 0
    @ViewState private var displayedMeetingID: UUID?
    @ViewState private var showsSpeakers = false
    @ViewState private var showsLiveText = false

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
    var body: some View {
        if let meeting {
            let editableCheckpoint = usesCheckpoint ? draft : nil
            let canSeek = !playback.isPlaybackBlocked && !meeting.audioFiles.isEmpty
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        TranscriptionActionButton(meeting: meeting, hasTranscript: !displayRows.isEmpty)
                        Spacer(minLength: 8)
                        historyMenu
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TranscriptionActionButton(meeting: meeting, hasTranscript: !displayRows.isEmpty)
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
                if displayedMeetingID != meetingID {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else if displayRows.isEmpty {
                    ContentUnavailableView(
                        "No Transcript Yet", systemImage: "text.bubble",
                        description: Text("Transcribe the recording to create a transcript.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    NativeTranscriptView(
                        rows: displayRows, generation: displayGeneration, showsSpeakers: showsSpeakers,
                        editable: store.libraryWritable && (!usesCheckpoint || canRestore), canPlay: canSeek,
                        playback: playback, meetingID: meetingID,
                        transcriptSourceID: meeting.transcriptSource?.id,
                        play: { seek($0, meeting: meeting) },
                        save: { id, text in
                            updateSegment(id, meetingID: meeting.id, text: text, checkpoint: editableCheckpoint)
                        },
                        speakerPicker: { id, completed in
                            if let speaker = meeting.speakers.first(where: { $0.id == id }) {
                                return AnyView(
                                    TranscriptSpeakerPicker(
                                        meetingID: meeting.id, speaker: speaker, completed: completed
                                    )
                                    .environmentObject(store))
                            }
                            return AnyView(Text("Speaker is unavailable."))
                        }
                    ).id(meetingID)
                    if !usesCheckpoint && !meeting.speakers.isEmpty {
                        DisclosureGroup("Speakers") {
                            ScrollView { MeetingSpeakersView(meetingID: meetingID) }.frame(maxHeight: 240)
                        }
                        .disclosureGroupStyle(AppDisclosureStyle())
                    }
                }
            }
            .task(id: meetingID) {
                loadHistory()
                refreshRows()
            }
            .onChange(of: meeting.transcript) { _, _ in
                loadHistory()
                refreshRows()
            }
            .onChange(of: meeting.speakers) { _, _ in refreshRows() }
            .onChange(of: meeting.transcriptSource) { _, _ in
                loadHistory()
                refreshRows()
            }
            .onChange(of: store.people) { _, _ in refreshRows() }
        }
    }
    @ViewBuilder private var historyMenu: some View {
        if let meeting, draft?.phrases.isEmpty == false || !meeting.transcript.isEmpty || !revisions.isEmpty {
            let choices = TranscriptRevisions.choices(revisions, current: meeting)
            let liveSource = draft.map { store.liveTranscriptSource($0, meeting: meeting) }
            Menu("Transcript History") {
                if let draft, !draft.phrases.isEmpty, let liveSource,
                    !choices.contains(where: { $0.id == liveSource.id })
                {
                    Button(
                        "\(liveSource.providerName) · \(liveSource.generatedAt.formatted(date: .abbreviated, time: .standard))"
                    ) {
                        _ = store.adoptLiveTranscript(draft, replacing: true)
                        loadHistory()
                    }
                }
                ForEach(choices) { revision in
                    let selected = revision.id == (meeting.transcriptSource?.id ?? meeting.id)
                    Button {
                        store.restoreTranscript(revision, meetingID: meetingID)
                        loadHistory()
                    } label: {
                        let name = revision.source?.providerName ?? "Transcript"
                        Label(
                            "\(name) · \(revision.savedAt.formatted(date: .abbreviated, time: .standard))",
                            systemImage: selected ? "checkmark" : "")
                    }.disabled(selected)
                }
            }.disabled(!canRestore)
        }
    }
    private func seek(_ time: Double, meeting: Meeting) {
        playback.play(meeting: meeting, files: store.audioURLs(for: meeting), at: time)
    }
    private func updateSegment(_ id: UUID, meetingID: UUID, text: String, checkpoint: LiveTranscriptDraft?) {
        if let checkpoint {
            guard checkpoint.meetingID == meetingID, store.adoptLiveTranscript(checkpoint) else { return }
        }
        guard var meeting = store.meeting(id: meetingID),
            let index = meeting.transcript.firstIndex(where: { $0.id == id })
        else {
            return
        }
        meeting.transcript[index].text = text
        store.updateMeeting(meeting)
    }
    private func refreshRows() {
        displayedMeetingID = meetingID
        guard let meeting else {
            displayRows = []
            displayGeneration += 1
            return
        }
        let people = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        let assignedPeople = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0.personID) })
        let names = Dictionary(
            uniqueKeysWithValues: meeting.speakers.map { speaker in
                (speaker.id, speaker.personID.flatMap { people[$0] } ?? SpeakerLabelPresentation.display(speaker.label))
            })
        let source = segments
        let checkpoint = usesCheckpoint
        showsSpeakers = !checkpoint && source.contains { !$0.speaker.isEmpty || $0.speakerID != nil }
        showsLiveText =
            checkpoint
            || (draft?.phrases.isEmpty == false && Set(source.map(\.id)) == Set(draft?.phrases.map(\.id) ?? []))
        func colorKey(_ segment: TranscriptSegment) -> String {
            let personID = segment.speakerID.flatMap { assignedPeople[$0] ?? nil }
            return personID?.uuidString ?? segment.speakerID?.uuidString ?? segment.speaker
        }
        let colorIndices = TranscriptSpeakerPalette.indices(for: source.map(colorKey))
        displayRows = source.map { segment in
            TranscriptDisplayRow(
                id: segment.id, start: segment.start,
                speaker: checkpoint
                    ? "" : segment.speakerID.flatMap { names[$0] } ?? SpeakerLabelPresentation.display(segment.speaker),
                speakerID: segment.speakerID,
                text: String(segment.text.drop(while: { $0.isWhitespace })),
                personID: segment.speakerID.flatMap { assignedPeople[$0] ?? nil },
                speakerColorIndex: colorIndices[colorKey(segment)])
        }
        displayGeneration += 1
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
