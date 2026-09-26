import SwiftUI

extension MeetingArchiveStatus {
    var symbol: String {
        switch self {
        case .archived: "checkmark.icloud"
        case .incomplete: "exclamationmark.icloud"
        }
    }
    /// Visible text in the meeting header.
    var title: String {
        switch self {
        case .archived(let host, let date):
            let place = host.isEmpty ? "Archived" : "Archived on \(host)"
            return date.map { "\(place) · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? place
        case .incomplete: return "Archive incomplete"
        }
    }
    /// VoiceOver text: spells out the date and the recovery action.
    var accessibilityText: String {
        switch self {
        case .archived(let host, let date):
            let place = host.isEmpty ? "Archived" : "Archived on \(host)"
            return date.map { "\(place), \($0.formatted(date: .long, time: .omitted))" } ?? place
        case .incomplete(let host):
            let target = host.isEmpty ? "Archive" : "Archive to \(host)"
            return "\(target) incomplete. Choose Archive to Server to resume."
        }
    }
}

/// Archive state in the meeting header. Nothing is shown for a meeting that was
/// never archived; an incomplete archive offers the same action as Meeting Actions.
struct MeetingArchiveStatusView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var server = GdayServerService.shared
    let meetingID: UUID

    var body: some View {
        if let status = store.archiveStatuses[meetingID] {
            HStack(spacing: 10) {
                Label(status.title, systemImage: status.symbol)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(status.accessibilityText)
                    .help(status.accessibilityText)
                if case .incomplete = status {
                    let canResume =
                        server.connected && !store.isJobRunning(.archive, .meeting(meetingID))
                        && !store.isJobRunning(.importAudio, .meeting(meetingID))
                        && store.recordingID != meetingID
                    Button("Archive to Server") { Task { await store.archiveToServer(id: meetingID) } }
                        .buttonStyle(.link)
                        // The header's secondary style would hide that this is an action;
                        // an explicit style also has to show the disabled state.
                        .foregroundStyle(canResume ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .disabled(!canResume)
                        .help(
                            server.connected
                                ? "Resume archiving this meeting"
                                : "Sign in to the Gday Meetings website in Service Providers to resume")
                }
            }
        }
    }
}

/// Quiet list indicator; the header carries the full description.
struct MeetingArchiveListIcon: View {
    let status: MeetingArchiveStatus

    var body: some View {
        Image(systemName: status.symbol)
            .accessibilityLabel(status.accessibilityText)
            .help(status.title)
    }
}
