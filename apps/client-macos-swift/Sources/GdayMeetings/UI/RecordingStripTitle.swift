import AppKit
import SwiftUI

/// Matches the player's single icon-and-title navigation target.
struct RecordingStripTitle: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void

    var body: some View {
        if let id = store.recordingID {
            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    revealMeeting(id)
                }
                else {
                    showMeeting(id)
                }
            } label: {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle())
            .help("Show the recording. Command-click to reveal its folder in Finder.")
            .accessibilityLabel("Show Recording")
            .accessibilityAction(named: "Reveal in Finder") { revealMeeting(id) }
        }
        else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 14) {
            if store.isStartingRecording || store.isFinalizingRecording {
                ProgressView().controlSize(.small)
            }
            else {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red).font(.title2).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    store.isStartingRecording
                        ? "Preparing Recording" : store.isFinalizingRecording ? "Saving Recording" : "Recording"
                )
                .font(.callout.weight(.semibold))
                if let id = store.recordingID, let meeting = store.meetings.first(where: { $0.id == id }) {
                    Text(meeting.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                else {
                    Text("Complete the macOS audio consent prompt.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func revealMeeting(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)])
    }
}
