import SwiftUI

enum MeetingContentTab: Int {
    case transcript, notes, summary, dataPrivacy
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    var initialTranscriptRowID: UUID? = nil
    var initialContentTab: MeetingContentTab? = nil
    var usesWindowToolbar = false
    var retainedTab: Binding<Int>? = nil
    @ViewState private var localTab = 0
    @ViewState private var showsDetails = false
    private var tab: Int {
        get { retainedTab?.wrappedValue ?? localTab }
        nonmutating set {
            if let retainedTab {
                retainedTab.wrappedValue = newValue
            }
            else {
                localTab = newValue
            }
        }
    }

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }
    private func change(_ edit: (inout Meeting) -> Void) {
        guard var value = meeting else { return }
        edit(&value)
        store.updateMeeting(value)
    }
    private func text(_ path: WritableKeyPath<Meeting, String>) -> Binding<String> {
        Binding(get: { meeting?[keyPath: path] ?? "" }, set: { value in change { $0[keyPath: path] = value } })
    }
    var body: some View { meetingBody }

    @ViewBuilder private var meetingBody: some View {
        if let meeting {
            detailContent(meeting)
                .modifier(AudioFileDrop(meetingID: meetingID))
                .onAppear {
                    if let initialContentTab {
                        tab = initialContentTab.rawValue
                    }
                    else if store.recordingID == meetingID {
                        tab = store.liveTranscript.enabled ? 0 : 1
                    }
                }
                .onChange(of: initialContentTab) { _, value in
                    if let value { tab = value.rawValue }
                }
                .onChange(of: initialTranscriptRowID) { _, rowID in
                    if rowID != nil { tab = 0 }
                }
                .onChange(of: store.recordingID) { _, id in
                    if id == meetingID { tab = store.liveTranscript.enabled ? 0 : 1 }
                }
        }
    }

    private func detailContent(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            meetingHeader(meeting)
            if store.recordingID == meetingID {
                RecordingWorkspaceView(meetingID: meetingID)
            }
            if !usesWindowToolbar {
                MeetingContentTabs(selection: Binding(get: { tab }, set: { tab = $0 }))
            }
            GeometryReader { viewport in
                meetingContent(meeting, tab: tab)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
        }.padding(.horizontal, AppTheme.contentInset).padding(.top, AppTheme.contentSpacing).padding(.bottom, 16)
    }

    private func meetingHeader(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if store.recordingID != meetingID && !meeting.audioFiles.isEmpty {
                    playbackButton(meeting)
                }
                MeetingTitleView(title: text(\.title), editable: store.libraryWritable) {
                    NSWorkspace.shared.open(store.directory(for: meetingID))
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                MeetingActionsMenu(meeting: meeting).labelStyle(.iconOnly).fixedSize()
            }
            if store.recordingID != meetingID {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    meetingDate(meeting).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        showsDetails.toggle()
                    } label: {
                        Label("Details", systemImage: hasArchiveIssue ? "exclamationmark.circle" : "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(
                        hasArchiveIssue
                            ? "Archive incomplete. Open meeting details to review."
                            : "Language, tags, and archive status"
                    )
                    .popover(isPresented: $showsDetails) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Meeting Details").font(.headline)
                            MeetingLanguagePicker(selection: text(\.language))
                            MeetingTagsView(meetingID: meetingID)
                            MeetingArchiveStatusView(meetingID: meetingID)
                        }
                        .padding(AppTheme.contentInset).frame(width: 360)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var hasArchiveIssue: Bool {
        if let status = store.archiveStatuses[meetingID], case .incomplete = status { return true }
        return false
    }

    private func meetingDate(_ meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            if meeting.duration > 0 && store.recordingID != meetingID {
                Text(formatTime(meeting.duration)).monospacedDigit().accessibilityLabel(
                    "Duration \(formatTime(meeting.duration))")
            }
        }
    }

    private func playbackButton(_ meeting: Meeting) -> some View {
        // HIG Playing Audio: start playback only after an intentional action.
        // Library browsing does not replace or pause the current recording.
        // https://developer.apple.com/design/human-interface-guidelines/playing-audio
        Button {
            if playback.meetingID == meetingID {
                playback.togglePlayPause()
            }
            else {
                playback.play(meeting: meeting, files: store.audioURLs(for: meeting))
            }
        } label: {
            Label(
                playbackActionTitle,
                systemImage: playback.meetingID == meetingID && playback.isPlaying ? "pause.fill" : "play.fill"
            )
            .labelStyle(.iconOnly)
            .font(.body)
            .frame(width: 28, height: 28)
        }
        .buttonStyle(MeetingPlaybackButtonStyle())
        .disabled(
            playback.isPlaybackBlocked || (playback.meetingID == meetingID && playback.isLoading)
                || meeting.audioFiles.isEmpty
        )
        .help(
            playback.isPlaybackBlocked
                ? "Playback is unavailable while recording" : "\(playbackActionTitle) this meeting")
    }

    private var playbackActionTitle: String {
        guard playback.meetingID == meetingID else { return "Play" }
        if playback.isLoading { return "Loading…" }
        if playback.isPlaying { return "Pause" }
        return "Play"
    }

    @ViewBuilder
    private func meetingContent(_ meeting: Meeting, tab: Int) -> some View {
        switch tab {
        case 0:
            if store.recordingID == meetingID {
                LiveTranscriptView(controller: store.liveTranscript)
            }
            else {
                MeetingTranscriptView(meetingID: meetingID, initialRowID: initialTranscriptRowID)
            }
        case 1:
            MeetingNotesWorkspace(meetingID: meetingID)
        case 2:
            VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                HStack {
                    Text("Summary").font(.headline)
                    Spacer()
                    Button(meeting.summary.isEmpty ? "Generate Summary" : "Regenerate Summary", systemImage: "sparkles")
                    { Task { await store.summarize(id: meetingID) } }
                    .modifier(MarkdownControlCursor())
                    .disabled(
                        store.isJobRunning(.summary, .meeting(meetingID))
                            || (meeting.transcript.isEmpty && meeting.notes.isEmpty))
                }
                SummaryReadingView(
                    drafts: store.summaryDrafts, meetingID: meetingID, summary: meeting.summary,
                    changed: store.libraryWritable ? { value in change { $0.summary = value } } : nil
                )
                .accessibilityLabel("Summary")
                .modifier(AppContentSurface())
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))

            }
        default: MeetingDataPrivacyView(meetingID: meetingID)
        }
    }

}

/// Only the document observes partial text; the header and library stay independent.
private struct SummaryReadingView: View {
    @ObservedObject var drafts: SummaryDraftState
    let meetingID: UUID
    let summary: String
    var changed: ((String) -> Void)?

    var body: some View {
        let draft = drafts.values[meetingID]
        MeetingMarkdownReadingView(
            meetingID: meetingID, markdown: draft ?? summary, showsTimestamps: false,
            emptyMessage: draft != nil
                ? "Writing summary…" : "No summary yet. Choose Generate Summary to create one.",
            changed: draft == nil ? changed : nil)
    }
}

private func formatTime(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, Int(min(seconds, Double(Int.max / 2)))) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

// The library owns this menu so detail replacement cannot duplicate toolbar items.
struct MeetingActionsMenu: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var server = GdayServerService.shared
    let meeting: Meeting
    @ViewState private var transcriptionConfirmation: TranscriptionConfirmation?

    var body: some View {
        Menu {
            TranscriptionActionButton(meeting: meeting, requestConfirmation: { transcriptionConfirmation = $0 })
            if meeting.transcriptionAttempt != nil {
                PendingTranscriptionActions(meeting: meeting, requestConfirmation: { transcriptionConfirmation = $0 })
            }
            Divider()
            Button("Export Meeting Text…", systemImage: "square.and.arrow.up") {
                MeetingPanels.export(meeting, store: store)
            }
            Button("Archive to Server", systemImage: "icloud.and.arrow.up") {
                Task { await store.archiveToServer(id: meeting.id) }
            }
            .disabled(
                !server.connected || store.isJobRunning(.archive, .meeting(meeting.id))
                    || store.isJobRunning(.importAudio, .meeting(meeting.id))
                    || store.recordingID == meeting.id)
        } label: {
            Label("Meeting Actions", systemImage: "ellipsis.circle")
        }
        .help("Transcribe, export, or archive this meeting")
        .modifier(TranscriptionConfirmationPresenter(meeting: meeting, confirmation: $transcriptionConfirmation))
    }
}
