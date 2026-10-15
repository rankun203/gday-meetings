import AppKit
import SwiftUI

struct MeetingNotesWorkspace: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var mode: NotesViewMode
    @ViewState private var editingSession: NotesEditingSession?
    init(meetingID: UUID, initiallyRecording: Bool) {
        self.meetingID = meetingID
        _mode = ViewState(initialValue: NotesViewMode(isRecordingOnEntry: initiallyRecording))
    }
    private var requestedReading: Bool { mode.reading }
    // Keep the editor visible until its draft has been saved successfully.
    private var reading: Bool { requestedReading && editingSession?.meetingID != meetingID }
    private var modeContext: NotesViewMode.Context {
        .init(meetingID: meetingID, reading: requestedReading)
    }
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
                        set: { value in
                            mode.reading = value
                        }
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
                    MeetingNotesReadingView(
                        meetingID: meetingID,
                        draft: store.notesStorage.draft(
                            meetingID, fallback: store.meeting(id: meetingID)?.notes ?? ""))
                }
            }
            .modifier(AppContentSurface())
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        }
        .task(id: meetingID) { await store.openNotes(id: meetingID, editing: false) }
        .task(id: modeContext) {
            let request = modeContext
            if let session = editingSession {
                guard await store.finishNotesEditing(id: session.meetingID, session: session.id) else {
                    if !Task.isCancelled, modeContext == request, session.meetingID == meetingID {
                        mode.reading = false
                    }
                    return
                }
                if editingSession == session { editingSession = nil }
            }
            guard !Task.isCancelled, modeContext == request, !requestedReading else { return }
            let session = NotesEditingSession(meetingID: meetingID)
            editingSession = session
            store.notesStorage.beginEditing(meetingID, session: session.id)
            await store.suspendSearchIndexForEditing(id: meetingID)
        }
        .onDisappear {
            let session = editingSession
            Task { await store.closeNotes(id: session?.meetingID ?? meetingID, session: session?.id) }
        }
        .id(meetingID)
    }
}

private struct NotesEditingSession: Equatable {
    let meetingID: UUID
    let id = UUID()
}

/// Constructed when Notes enters the visible hierarchy, never from live recording updates.
struct NotesViewMode {
    struct Context: Equatable {
        let meetingID: UUID
        let reading: Bool
    }
    var reading: Bool
    init(isRecordingOnEntry: Bool) { reading = !isRecordingOnEntry }
}

private struct MeetingNotesReadingView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ObservedObject var draft: NotesDraft
    var body: some View {
        MeetingMarkdownReadingView(
            meetingID: meetingID, markdown: draft.text, showsTimestamps: true,
            emptyMessage: "No notes yet. Choose Edit Notes to add notes.",
            changed: store.libraryWritable ? { store.editNotes(id: meetingID, text: $0) } : nil)
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
