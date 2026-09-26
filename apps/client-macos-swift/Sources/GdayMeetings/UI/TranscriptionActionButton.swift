import SwiftUI

/// Routine transcription starts directly; destructive result replacement asks first.
struct TranscriptionActionButton: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @ViewState private var confirming = false
    let meeting: Meeting

    private var provider: ServiceProvider? { try? store.transcriptionProvider(for: meeting) }
    /// A provider is ready but no default is chosen: Defaults is the next step.
    /// Otherwise the provider itself needs setup in Service Providers.
    private var defaultNeedsChoosing: Bool {
        meeting.transcriptionAttempt == nil && store.settings.transcriptionProviderID == nil
            && store.settings.serviceProviders.contains {
                ProviderConfigurationEligibility.canSelect(
                    $0, for: .transcription, providers: store.settings.serviceProviders)
            }
    }
    private var title: String {
        if meeting.transcriptionAttempt?.result != nil { return "Apply Saved Transcript…" }
        if meeting.transcriptionAttempt != nil { return "Resume Transcription" }
        guard let provider else { return "Set Up Transcription…" }
        return "Transcribe with \(provider.name)"
    }
    var body: some View {
        Button(title, systemImage: "text.bubble") {
            if meeting.transcriptionAttempt?.result != nil {
                confirming = true
            }
            else if provider == nil {
                settingsTab = defaultNeedsChoosing ? "defaults" : "providers"
                openSettings()
            }
            else {
                Task { await store.transcribe(id: meeting.id) }
            }
        }
        .disabled(
            store.isJobRunning(.transcription, .meeting(meeting.id))
                || store.isJobRunning(.importAudio, .meeting(meeting.id)) || meeting.audioFiles.isEmpty
                || store.recordingID == meeting.id
        )
        .confirmationDialog("Replace the current transcript?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace Transcript", role: .destructive) {
                store.applySavedTranscriptionResult(meetingID: meeting.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved result will replace the current transcript and its edits. The recording is kept.")
        }
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
