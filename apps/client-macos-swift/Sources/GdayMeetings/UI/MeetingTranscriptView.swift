import SwiftUI

/// Saved transcript actions stay outside the text viewport. Old live checkpoints
/// remain readable, and the first edit adopts them through the same safe store API.
struct MeetingTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @ObservedObject private var localModels = LocalModelManager.shared
    let meetingID: UUID
    var initialRowID: UUID? = nil
    @StateObject private var historyReader = TranscriptHistoryReader()
    @ViewState private var historyOwner: TranscriptHistoryReadKey?
    @ViewState private var draft: LiveTranscriptDraft?
    @ViewState private var revisions: [TranscriptRevision] = []
    @ViewState private var transcriptChoices: [TranscriptRevision] = []
    @ViewState private var labelChoices: [TranscriptRevision] = []
    @ViewState private var failure: String?
    @ViewState private var displayRows: [TranscriptDisplayRow] = []
    @ViewState private var visibleRows: [TranscriptDisplayRow] = []
    @ViewState private var displayGeneration = 0
    @ViewState private var displayedMeetingID: UUID?
    @ViewState private var showsSpeakers = false
    @ViewState private var showsLiveText = false
    @ViewState private var labelingHistory: SpeakerLabelingHistory?
    @ViewState private var showsLabelingHistory = false

    private var historyReadKey: TranscriptHistoryReadKey {
        .init(
            directory: store.dataDirectory, meetingID: meetingID,
            source: meeting?.transcriptSource, labelingSource: meeting?.speakerLabelSource)
    }
    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }
    private var usesCheckpoint: Bool {
        meeting?.transcript.isEmpty == true && meeting?.liveTranscriptAdopted != true && draft?.hasUsableText == true
    }
    private var segments: [TranscriptSegment] { usesCheckpoint ? draft?.segments ?? [] : meeting?.transcript ?? [] }
    private var playbackVisibility: TranscriptPlaybackVisibility {
        TranscriptPlaybackVisibility(
            meetingID: playback.meetingID,
            audioFiles: playback.trackNames.indices.compactMap { playback.audioURL(forTrack: $0)?.lastPathComponent },
            mutedTracks: playback.mutedTracks)
    }
    private var labelingTasks: [ManagedTaskRecord] {
        store.managedTasks.filter { $0.meetingID == meetingID && $0.kind == .diarization }
    }
    private var labelingHistoryKey: SpeakerLabelingHistoryReadKey {
        .init(
            meetingID: meetingID, sourceID: meeting?.transcriptSource?.id,
            labelingResultID: meeting?.speakerLabelSource?.resultID,
            taskStates: ["journal:\(store.managedTaskRevision)"]
                + labelingTasks.map {
                    $0.id.uuidString + ":" + $0.state.rawValue + ":" + ($0.speakerLabelingResultID?.uuidString ?? "")
                })
    }
    private var canRestore: Bool {
        store.libraryWritable && store.recordingID != meetingID && meeting?.transcriptionAttempt == nil
            && !store.isJobRunning(.transcription, .meeting(meetingID))
            && !store.isJobRunning(.diarization, .meeting(meetingID))
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
                        speakerLabelAction
                        labelingHistoryButton
                        historyMenu
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                TranscriptionActionButton(meeting: meeting, hasTranscript: !displayRows.isEmpty)
                                speakerLabelAction
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                TranscriptionActionButton(meeting: meeting, hasTranscript: !displayRows.isEmpty)
                                speakerLabelAction
                            }
                        }
                        HStack {
                            labelingHistoryButton
                            historyMenu
                        }
                    }
                }
                .controlSize(.small)
                if showsLiveText {
                    Text(
                        draft?.complete == true
                            ? "Live transcript · This Mac" : "Live transcript · This Mac · Some audio may be missing."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
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
                else if visibleRows.isEmpty {
                    ContentUnavailableView(
                        "Transcript Hidden", systemImage: "speaker.slash",
                        description: Text("Unmute an audio track to show its transcript.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    NativeTranscriptView(
                        rows: visibleRows, generation: displayGeneration, showsSpeakers: showsSpeakers,
                        editable: store.libraryWritable && (!usesCheckpoint || canRestore), canPlay: canSeek,
                        playback: playback, meetingID: meetingID,
                        transcriptSourceID: meeting.transcriptSource?.id,
                        initialRowID: initialRowID,
                        play: { seek($0, meeting: meeting) },
                        save: { id, text in
                            updateSegment(id, meetingID: meeting.id, text: text, checkpoint: editableCheckpoint)
                        },
                        speakerPicker: { id, completed in
                            if let speaker = (editableCheckpoint?.speakers ?? meeting.speakers).first(where: {
                                $0.id == id
                            }) {
                                return AnyView(
                                    TranscriptSpeakerPicker(
                                        meetingID: meeting.id, speaker: speaker, completed: completed,
                                        assignment: { personID in
                                            if let editableCheckpoint {
                                                guard await store.adoptLiveTranscript(editableCheckpoint) else {
                                                    return
                                                }
                                            }
                                            await store.assignSpeaker(
                                                meetingID: meeting.id, speakerID: id, personID: personID)
                                        }
                                    )
                                    .environmentObject(store))
                            }
                            return AnyView(Text("Speaker is unavailable."))
                        }
                    ).id(meetingID)
                    if !usesCheckpoint && meeting.speakers.contains(where: { $0.canAssignPerson || $0.personID != nil })
                    {
                        DisclosureGroup("Speakers") {
                            ScrollView { MeetingSpeakersView(meetingID: meetingID) }.frame(maxHeight: 240)
                        }
                        .disclosureGroupStyle(AppDisclosureStyle())
                    }
                }
            }
            .task(id: historyReadKey) { await loadHistory() }
            .task(id: labelingHistoryKey) { await loadLabelingHistory() }
            .onChange(of: meeting.transcript) { _, _ in
                refreshHistoryChoices()
                refreshRows()
            }
            .onChange(of: meeting.speakers) { _, _ in
                refreshHistoryChoices()
                refreshRows()
            }
            .onChange(of: store.people) { _, _ in refreshRows() }
            .onChange(of: playbackVisibility) { _, _ in refreshVisibleRows() }
        }
    }
    @ViewBuilder private var speakerLabelAction: some View {
        if store.isJobRunning(.diarization, .meeting(meetingID)) {
            Button("Cancel Speaker Labeling") { Task { await store.cancelLocalDiarization(id: meetingID) } }
                .help(labelingHistoryHelp)
        }
        else if store.settings.serviceProviders.contains(where: {
            $0.id == store.settings.diarizationProviderID && $0.kind == .community1 && $0.supports(.diarization)
        }) {
            Button("Label Speakers") {
                Task {
                    if usesCheckpoint, let draft, !(await store.adoptLiveTranscript(draft)) { return }
                    await store.diarizeLocally(id: meetingID)
                }
            }
            .disabled(
                !canRestore
                    || meeting?.audioFiles.isEmpty != false || displayRows.isEmpty
                    || localModels.state(for: .community1).phase != .ready
            )
            .help(labelingHistoryHelp)
        }
    }

    private var labelingHistoryButton: some View {
        Button("Labelings", systemImage: "clock.arrow.circlepath") {
            showsLabelingHistory = true
        }
        .labelStyle(.titleAndIcon)
        .help("Speaker Labeling History")
        .accessibilityLabel("Labelings")
        .popover(isPresented: $showsLabelingHistory) {
            SpeakerLabelingHistoryView(
                history: $labelingHistory, restoreChoices: labelChoices,
                currentSnapshotID: meeting.map { TranscriptRevisions.current($0).id }, canRestore: canRestore
            ) { revision in
                Task { if await store.restoreSpeakerLabels(revision, meetingID: meetingID) { await loadHistory() } }
            }
        }
    }

    private var labelingHistoryHelp: String {
        let readiness =
            localModels.state(for: .community1).phase == .ready
            ? "Label speakers in saved audio without changing the text."
            : "Download and prepare Community-1 in Service Providers."
        guard let labelingHistory else { return readiness + "\nLoading speaker labeling history…" }
        guard let latest = labelingHistory.entries.max(by: { $0.date < $1.date }) else {
            return readiness + "\nNo recorded speaker labeling history."
        }
        let date = latest.date.formatted(date: .abbreviated, time: .shortened)
        return readiness
            + "\nLatest record: \(date) · \(latest.providerName ?? "Provider not recorded") · \(latest.status)."
    }

    private func loadLabelingHistory() async {
        let key = labelingHistoryKey
        labelingHistory = nil
        let journal = store.managedTaskJournal
        let id = meetingID
        let (tasks, taskWarning) = await Task.detached(priority: .utility) { () -> ([ManagedTaskRecord], String?) in
            do {
                return (
                    try journal.query(
                        where: "meeting=" + ManagedTaskIndex.literal(id.uuidString) + " AND kind='diarization'",
                        limit: 501), nil
                )
            }
            catch {
                return ([], "Couldn’t read speaker-labeling tasks. \(error.localizedDescription)")
            }
        }.value
        var result = await SpeakerLabelingHistory.load(
            directory: store.directory(for: meetingID),
            tasks: Array(tasks.prefix(500)) + labelingTasks.filter(\.isPreview),
            currentSourceID: key.sourceID, currentLabelingResultID: key.labelingResultID)
        let warnings = [
            result.warning, taskWarning,
            tasks.count > 500 ? "Showing the latest 500 speaker-labeling tasks." : nil,
        ].compactMap { $0 }
        result.warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        guard !Task.isCancelled, key == labelingHistoryKey else { return }
        labelingHistory = result
    }
    @ViewBuilder private var historyMenu: some View {
        if let meeting, draft?.hasUsableText == true || !meeting.transcript.isEmpty || !revisions.isEmpty {
            let choices = transcriptChoices
            let liveSource = draft.map { store.liveTranscriptSource($0, meeting: meeting) }
            Menu("Transcripts", systemImage: "doc.on.doc") {
                if let draft, draft.hasUsableText, let liveSource,
                    !choices.contains(where: { ($0.source?.id ?? $0.id) == liveSource.id })
                {
                    Button(
                        "\(liveSource.providerName) · \(liveSource.generatedAt.formatted(date: .abbreviated, time: .standard))"
                    ) {
                        Task {
                            _ = await store.adoptLiveTranscript(draft, replacing: true)
                            await loadHistory()
                        }
                    }
                }
                ForEach(choices) { revision in
                    let selected = revision.id == TranscriptRevisions.current(meeting).id
                    Button {
                        Task {
                            await store.restoreTranscript(revision, meetingID: meetingID)
                            await loadHistory()
                        }
                    } label: {
                        let name = transcriptChoiceTitle(revision, meeting: meeting)
                        let title = "\(name) · \(revision.savedAt.formatted(date: .abbreviated, time: .standard))"
                        if selected {
                            Label(title, systemImage: "checkmark")
                        }
                        else {
                            Text(title)
                        }
                    }.disabled(selected)
                }
            }.disabled(!canRestore)
                .labelStyle(.titleAndIcon)
                .help("Transcript History")
                .accessibilityLabel("Transcripts")
        }
    }
    private func seek(_ time: Double, meeting: Meeting) {
        playback.play(meeting: meeting, files: store.audioURLs(for: meeting), at: time)
    }
    private func updateSegment(_ id: UUID, meetingID: UUID, text: String, checkpoint: LiveTranscriptDraft?) {
        Task {
            if let checkpoint {
                guard checkpoint.meetingID == meetingID, await store.adoptLiveTranscript(checkpoint) else { return }
            }
            guard var meeting = store.meeting(id: meetingID),
                let index = meeting.transcript.firstIndex(where: { $0.id == id })
            else {
                return
            }
            meeting.transcript[index].text = text
            await store.updateMeeting(meeting)
        }
    }
    private func refreshRows() {
        displayedMeetingID = meetingID
        guard let meeting else {
            displayRows = []
            visibleRows = []
            displayGeneration += 1
            return
        }
        let people = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        let speakers = usesCheckpoint ? draft?.speakers ?? [] : meeting.speakers
        let speakerTracks = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.track) })
        let speakerSlots = MeetingSpeakerColors.slots(for: speakers)
        let speakerOrigins = Dictionary(
            uniqueKeysWithValues: speakers.map { ($0.id, MeetingSpeakerColors.identity($0)) })
        let assignedPeople = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.personID) })
        let sourceIDs = Set(speakers.filter { !$0.canAssignPerson }.map(\.id))
        let names = Dictionary(
            uniqueKeysWithValues: speakers.map { speaker in
                (speaker.id, speaker.personID.flatMap { people[$0] } ?? speaker.displayLabel)
            })
        let source = segments
        let checkpoint = usesCheckpoint
        showsSpeakers = source.contains { !$0.speaker.isEmpty || $0.speakerID != nil }
        showsLiveText =
            checkpoint
            || (draft?.hasUsableText == true && Set(source.map(\.id)) == Set(draft?.segments.map(\.id) ?? []))
        func colorKey(_ segment: TranscriptSegment) -> String {
            if let speakerID = segment.speakerID { return (speakerOrigins[speakerID] ?? speakerID).uuidString }
            return TranscriptSpeakerPalette.displayKey(
                personID: nil, track: segment.speakerID.flatMap { speakerTracks[$0] } ?? "", label: segment.speaker)
        }
        let colorIndices = TranscriptSpeakerPalette.indices(
            for: source.map(colorKey),
            preserving: Dictionary(uniqueKeysWithValues: speakerSlots.map { ($0.key.uuidString, $0.value) }))
        displayRows = source.map { segment in
            TranscriptDisplayRow(
                id: segment.id, start: segment.start, end: segment.end,
                speaker: segment.speakerID.flatMap { names[$0] } ?? SpeakerLabelPresentation.display(segment.speaker),
                speakerID: segment.speakerID,
                text: String(segment.text.drop(while: { $0.isWhitespace })),
                personID: segment.speakerID.flatMap { assignedPeople[$0] ?? nil },
                speakerColorIndex: segment.speakerID.flatMap { speakerOrigins[$0] }.flatMap { speakerSlots[$0] }
                    ?? colorIndices[colorKey(segment)],
                speakerColorKey: colorKey(segment),
                isSourcePlaceholder: segment.speakerID.map { sourceIDs.contains($0) } ?? false)
        }
        refreshVisibleRows()
    }

    private func refreshVisibleRows() {
        let hidden = playbackVisibility.hiddenSegments(
            meetingID: meetingID, segments: segments,
            speakers: usesCheckpoint ? draft?.speakers ?? [] : meeting?.speakers ?? [],
            audioFiles: meeting?.audioFiles ?? [])
        visibleRows = displayRows.filter { !hidden.contains($0.id) }
        displayGeneration += 1
    }

    private func loadHistory() async {
        let key = historyReadKey
        if historyOwner?.meetingID != key.meetingID || historyOwner?.directory != key.directory {
            draft = nil
            revisions = []
            transcriptChoices = []
            labelChoices = []
            failure = nil
            historyOwner = key
        }
        refreshRows()
        guard let result = await historyReader.load(key), !Task.isCancelled, key == historyReadKey else { return }
        draft = result.draft
        revisions = result.revisions
        failure = result.failure
        refreshHistoryChoices()
        refreshRows()
    }

    private func refreshHistoryChoices() {
        guard let meeting else {
            transcriptChoices = []
            labelChoices = []
            return
        }
        transcriptChoices = TranscriptRevisions.choices(revisions, current: meeting)
        labelChoices = TranscriptRevisions.labelingChoices(revisions, current: meeting)
    }

    private func transcriptChoiceTitle(_ revision: TranscriptRevision, meeting: Meeting) -> String {
        if TranscriptRevisions.isLegacyLabeling(revision) { return "Transcript and Labels" }
        let name = revision.source?.providerName ?? "Transcript"
        if revision.source?.id == meeting.transcriptSource?.id,
            revision.id != TranscriptRevisions.current(meeting).id
        {
            return name + " · Earlier Text"
        }
        return name
    }
}
