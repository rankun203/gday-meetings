import SwiftUI

struct MeetingDetailSheet: View {
    let meetingID: UUID
    var initialTranscriptRowID: UUID? = nil
    var initialContentTab: MeetingContentTab? = nil
    var close: () -> Void
    @Environment(\.showManagedTask) private var showManagedTask

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.padding()
            MeetingDetailView(
                meetingID: meetingID,
                initialTranscriptRowID: initialTranscriptRowID,
                initialContentTab: initialContentTab
            )
        }.frame(width: 800, height: 650)
            .environment(\.showManagedTask) { id in
                close()
                showManagedTask(id)
            }
    }
}
