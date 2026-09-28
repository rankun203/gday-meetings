import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    @ViewState private var tab = 0
    @ViewState private var chatDraft = ""

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }
    private func change(_ edit: (inout Meeting) -> Void) {
        guard var value = meeting else { return }
        edit(&value)
        store.updateMeeting(value)
    }
    private func text(_ path: WritableKeyPath<Meeting, String>) -> Binding<String> {
        Binding(get: { meeting?[keyPath: path] ?? "" }, set: { value in change { $0[keyPath: path] = value } })
    }
    var body: some View {
        if let meeting {
            detailContent(meeting)
                .modifier(AudioFileDrop(meetingID: meetingID))
                .navigationTitle(meeting.title)
                .onAppear { if store.recordingID == meetingID { tab = store.liveTranscript.enabled ? 0 : 1 } }
                .onChange(of: store.recordingID) { _, id in
                    if id == meetingID { tab = store.liveTranscript.enabled ? 0 : 1 }
                }
        }
    }

    private func detailContent(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            meetingHeader(meeting)
            if store.recordingID == meetingID {
                RecordingWorkspaceView(meetingID: meetingID)
            }
            MeetingContentTabs(selection: $tab)
            meetingContent(meeting).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
    }

    private func meetingHeader(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if store.recordingID != meetingID && !meeting.audioFiles.isEmpty {
                    playbackButton(meeting)
                }
                MeetingTitleView(title: text(\.title), editable: store.libraryWritable)
                    .layoutPriority(1)
            }
            if store.recordingID != meetingID {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        meetingDate(meeting).fixedSize()
                        Spacer(minLength: 8)
                        MeetingLanguagePicker(
                            selection: text(\.language),
                            compact: true
                        )
                        .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        meetingDate(meeting)
                        MeetingLanguagePicker(
                            selection: text(\.language),
                            compact: true
                        )
                        .fixedSize()
                    }
                }.font(.callout).foregroundStyle(.secondary)
                MeetingArchiveStatusView(meetingID: meetingID).font(.callout).foregroundStyle(.secondary)
                MeetingTagsView(meetingID: meetingID)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
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
    private func meetingContent(_ meeting: Meeting) -> some View {
        switch tab {
        case 0:
            if store.recordingID == meetingID {
                LiveTranscriptView(controller: store.liveTranscript)
            }
            else {
                MeetingTranscriptView(meetingID: meetingID)
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                if store.recordingID == meetingID {
                    HStack {
                        Text("Meeting Notes").font(.headline)
                        Spacer()
                        Text("Saved as you type").font(.caption).foregroundStyle(.secondary)
                    }
                }
                MeetingNotesWorkspace(meetingID: meetingID)
            }
        case 2:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Summary").font(.headline)
                    Spacer()
                    Button(meeting.summary.isEmpty ? "Generate Summary" : "Regenerate Summary", systemImage: "sparkles")
                    { Task { await store.summarize(id: meetingID) } }
                    .disabled(
                        store.isJobRunning(.summary, .meeting(meetingID))
                            || (meeting.transcript.isEmpty && meeting.notes.isEmpty))
                }
                MeetingMarkdownReadingView(
                    meetingID: meetingID, markdown: store.summaryDrafts[meetingID] ?? meeting.summary,
                    showsTimestamps: false,
                    emptyMessage: store.summaryDrafts[meetingID] != nil
                        ? "Writing summary…" : "No summary yet. Choose Generate Summary to create one.",
                    changed: store.libraryWritable && store.summaryDrafts[meetingID] == nil
                        ? { value in change { $0.summary = value } } : nil
                )
                .accessibilityLabel("Summary")
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))

            }
        default: chat(meeting)
        }
    }

    private func chat(_ meeting: Meeting) -> some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if meeting.chat.isEmpty {
                            Text("Ask questions about this meeting. Your transcript and notes provide context.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(meeting.chat) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : "Gday").font(.headline)
                                Text(message.content).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                    }.padding(6)
                }.onChange(of: meeting.chat.count) { _, _ in
                    if let id = meeting.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom) {
                TextField("Ask about this meeting", text: $chatDraft, axis: .vertical).lineLimit(1...5).onSubmit(
                    sendChat)
                Button("Send", systemImage: "arrow.up", action: sendChat).disabled(
                    store.isJobRunning(.chat, .meeting(meetingID))
                        || chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatDraft = ""
        Task { await store.sendChat(id: meetingID, message: text) }
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

    var body: some View {
        Menu {
            TranscriptionActionButton(meeting: meeting)
            if meeting.transcriptionAttempt != nil {
                PendingTranscriptionActions(meeting: meeting)
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
    }
}
