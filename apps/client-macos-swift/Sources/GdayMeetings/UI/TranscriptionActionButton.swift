import SwiftUI

/// Provider choice applies only to this request. Existing requests always resume
/// with their saved provider, rather than silently starting a different paid job.
struct TranscriptionActionButton: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.showManagedTask) private var showManagedTask
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @ViewState private var confirmation: TranscriptionConfirmation?
    let meeting: Meeting
    var hasTranscript: Bool? = nil
    var requestConfirmation: ((TranscriptionConfirmation) -> Void)? = nil

    private var providers: [ServiceProvider] { store.eligibleTranscriptionProviders }
    private var verb: String { (hasTranscript ?? !meeting.transcript.isEmpty) ? "Re-transcribe" : "Transcribe" }
    private var busy: Bool {
        store.isJobRunning(.transcription, .meeting(meeting.id))
            || store.isJobRunning(.importAudio, .meeting(meeting.id)) || store.recordingID == meeting.id
    }
    var body: some View {
        Group {
            if let task = store.managedTasks.first(where: {
                $0.meetingID == meeting.id && $0.kind == .transcription && $0.state.isActive
            }) {
                Button(
                    task.state == .queued ? "Queued · Show Task" : "Transcribing…",
                    systemImage: "list.bullet.rectangle"
                ) {
                    showManagedTask(task.id)
                }
                .help("Show this transcription in Tasks")
            }
            else if meeting.transcriptionAttempt?.result != nil {
                Button("Apply Saved Transcript…", systemImage: "text.bubble") {
                    if let requestConfirmation {
                        requestConfirmation(.applySavedTranscript)
                    }
                    else {
                        confirmation = .applySavedTranscript
                    }
                }
                .disabled(busy)
            }
            else if meeting.transcriptionAttempt != nil {
                Button("Resume Transcription", systemImage: "text.bubble") {
                    Task { await store.transcribe(id: meeting.id) }
                }.disabled(busy || meeting.audioFiles.isEmpty)
            }
            else if !providers.isEmpty {
                Menu(verb, systemImage: "text.bubble") {
                    ForEach(providers) { provider in
                        Button(provider.name) { start(provider) }
                            .accessibilityLabel("\(verb) with \(provider.name)")
                    }
                }.disabled(busy || meeting.audioFiles.isEmpty)
            }
            else {
                Button("Set Up Transcription…", systemImage: "text.bubble") {
                    settingsTab = "providers"
                    openSettings()
                }
            }
        }
        .modifier(TranscriptionConfirmationPresenter(meeting: meeting, confirmation: $confirmation))
    }
    private func start(_ provider: ServiceProvider) {
        Task { await store.transcribe(id: meeting.id, providerID: provider.id) }
    }
}

/// Recovery is explicit because a lost submit response may still represent a paid job.
struct PendingTranscriptionActions: View {
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var confirmation: TranscriptionConfirmation?
    let meeting: Meeting
    var requestConfirmation: ((TranscriptionConfirmation) -> Void)? = nil
    var body: some View {
        Button("Discard Pending Request…", role: .destructive) {
            if let requestConfirmation {
                requestConfirmation(.discardPendingRequest)
            }
            else {
                confirmation = .discardPendingRequest
            }
        }
        .disabled(store.isJobRunning(.transcription, .meeting(meeting.id)))
        .modifier(TranscriptionConfirmationPresenter(meeting: meeting, confirmation: $confirmation))
    }
}

enum TranscriptionConfirmation: Equatable {
    case applySavedTranscript
    case discardPendingRequest
}

/// Menu actions request presentation from the containing view: a dismissed
/// native menu must not own the confirmation's lifetime or presentation anchor.
struct TranscriptionConfirmationPresenter: ViewModifier {
    @EnvironmentObject private var store: MeetingStore
    let meeting: Meeting
    @Binding var confirmation: TranscriptionConfirmation?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            confirmation == .discardPendingRequest
                ? "Discard this pending request?" : "Replace the current transcript?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if confirmation == .discardPendingRequest {
                Button("Discard Pending Request", role: .destructive) {
                    Task {
                        do { try await store.clearTranscriptionAttempt(meetingID: meeting.id) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
            else {
                Button("Replace Transcript") {
                    Task { await store.applySavedTranscriptionResult(meetingID: meeting.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if confirmation == .discardPendingRequest, meeting.transcriptionAttempt?.providerID == ThisMacProvider.id {
                Text(
                    "This removes the saved transcription request and any unapplied result. The current transcript and recording are kept."
                )
            }
            else if confirmation == .discardPendingRequest {
                Text(
                    "This removes the saved job reference and any unapplied result from this Mac. It does not cancel the provider's job or remove uploaded audio. Check the provider's job history first. Starting another transcription may incur another charge."
                )
            }
            else {
                Text("The current transcript and its edits will be kept in Transcripts. The recording is kept.")
            }
        }
    }
}
