import AppKit
import SwiftUI

struct MeetingNotesWorkspace: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var reading = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    if store.flushNotes() { reading.toggle() }
                } label: {
                    Image(systemName: reading ? "pencil" : "book")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(reading ? "Edit notes" : "Read notes")
                .accessibilityLabel(reading ? "Edit Notes" : "Read Notes")
                .accessibilityValue(reading ? "Reading mode" : "Editing mode")
            }
            .padding(8)
            ZStack {
                MeetingNotesEditor(meetingID: meetingID, showsPanelBorder: false, editingEnabled: !reading)
                    .opacity(reading ? 0 : 1)
                    .allowsHitTesting(!reading)
                    .accessibilityHidden(reading)
                if reading {
                    MeetingMarkdownReadingView(
                        meetingID: meetingID,
                        markdown: store.meetings.first { $0.id == meetingID }?.notes ?? "",
                        showsTimestamps: true,
                        emptyMessage: "No notes yet. Choose Edit Notes to add notes.",
                        changed: store.libraryWritable ? { store.editNotes(id: meetingID, text: $0) } : nil)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        .task(id: meetingID) { store.openNotes(id: meetingID) }
        .onDisappear { store.closeNotes(id: meetingID) }
        .id(meetingID)
    }
}

struct MeetingMarkdownReadingView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    let markdown: String
    let showsTimestamps: Bool
    let emptyMessage: String
    var changed: ((String) -> Void)? = nil
    var body: some View {
        NativeMarkdownReadingView(
            markdown: markdown, showsTimestamps: showsTimestamps, emptyMessage: emptyMessage,
            directory: store.directory(for: meetingID), changed: changed,
            play: { time in
                guard !playback.isPlaybackBlocked,
                    let meeting = store.meetings.first(where: { $0.id == meetingID }), !meeting.audioFiles.isEmpty
                else { return }
                playback.play(meeting: meeting, files: store.audioURLs(for: meeting), at: time)
            }
        )
        .id(meetingID)
    }
}
