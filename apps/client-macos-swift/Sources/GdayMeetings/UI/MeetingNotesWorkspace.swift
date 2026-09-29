import AppKit
import SwiftUI

struct MeetingNotesWorkspace: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var reading = false
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if store.recordingID == meetingID {
                    Text("Meeting Notes").font(.headline)
                }
                Spacer()
                if store.recordingID == meetingID {
                    Text("Saved as you type").font(.caption).foregroundStyle(.secondary)
                }
                Picker(
                    "Notes View",
                    selection: Binding(
                        get: { reading },
                        set: { value in if store.flushNotes() { reading = value } }
                    )
                ) {
                    Image(systemName: "pencil").help("Edit notes").accessibilityLabel("Edit Notes").tag(false)
                    Image(systemName: "book").help("Read notes").accessibilityLabel("Read Notes").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 76)
                .accessibilityLabel("Notes View")
                .modifier(MarkdownControlCursor())
            }
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
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        }
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
