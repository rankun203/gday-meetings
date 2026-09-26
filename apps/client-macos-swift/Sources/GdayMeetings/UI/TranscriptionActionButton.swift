import SwiftUI

/// Provider choice applies only to this request. Existing requests always resume
/// with their saved provider, rather than silently starting a different paid job.
struct TranscriptionActionButton: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @ViewState private var confirming = false
    let meeting: Meeting
    var hasTranscript: Bool? = nil

    private var providers: [ServiceProvider] { store.eligibleTranscriptionProviders }
    private var verb: String { (hasTranscript ?? !meeting.transcript.isEmpty) ? "Re-transcribe" : "Transcribe" }
    private var busy: Bool {
        store.isJobRunning(.transcription, .meeting(meeting.id))
            || store.isJobRunning(.importAudio, .meeting(meeting.id)) || store.recordingID == meeting.id
    }
    var body: some View {
        Group {
            if meeting.transcriptionAttempt?.result != nil {
                Button("Apply Saved Transcript…", systemImage: "text.bubble") { confirming = true }
                    .disabled(busy)
            }
            else if meeting.transcriptionAttempt != nil {
                Button("Resume Transcription", systemImage: "text.bubble") {
                    Task { await store.transcribe(id: meeting.id) }
                }.disabled(busy || meeting.audioFiles.isEmpty)
            }
            else if providers.count == 1, let provider = providers.first {
                Button("\(verb) with \(provider.name)", systemImage: "text.bubble") {
                    start(provider)
                }.disabled(busy || meeting.audioFiles.isEmpty)
            }
            else if providers.count > 1 {
                Menu(verb, systemImage: "text.bubble") {
                    ForEach(providers) { provider in
                        Button("\(verb) with \(provider.name)") { start(provider) }
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
        .confirmationDialog("Replace the current transcript?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace Transcript") { store.applySavedTranscriptionResult(meetingID: meeting.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current transcript and its edits will be kept in Transcript History. The recording is kept.")
        }
    }
    private func start(_ provider: ServiceProvider) {
        Task { await store.transcribe(id: meeting.id, providerID: provider.id) }
    }
}

/// Recovery is explicit because a lost submit response may still represent a paid job.
struct PendingTranscriptionActions: View {
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var confirming = false
    let meeting: Meeting
    var body: some View {
        Button("Discard Pending Request…", role: .destructive) { confirming = true }
            .disabled(store.isJobRunning(.transcription, .meeting(meeting.id)))
            .confirmationDialog("Discard this pending request?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Discard Pending Request", role: .destructive) {
                    do { try store.clearTranscriptionAttempt(meetingID: meeting.id) }
                    catch { store.errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes the saved job reference and any unapplied result from this Mac. It does not cancel the provider's job or remove uploaded audio. Check the provider's job history first. Starting another transcription may incur another charge."
                )
            }
    }
}
