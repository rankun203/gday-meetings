import SwiftUI

// Shared evidence playback and preparation used by the person review flow.
struct VoicePreparationControls: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var library: VoiceLibraryStore
    @ViewState private var expanded = false
    @ViewState private var providerID: UUID?
    @ViewState private var loading = false
    @ViewState private var error: String?
    private var provider: ServiceProvider? {
        store.settings.serviceProviders.first { $0.id == providerID }
    }
    private var active: Bool {
        library.jobs.contains { $0.state == .running || $0.state == .queued }
    }
    var body: some View {
        DisclosureGroup("Speaker Association", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Prepare reviewed examples for a provider, or find voices in saved recordings. Review examples before using them to identify people."
                )
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Provider", selection: $providerID) {
                        Text("Choose a Provider").tag(UUID?.none)
                        ForEach(
                            store.settings.serviceProviders.filter {
                                $0.kind.isLocalSpeaker
                                    || $0.kind.capabilities.contains(.diarization)
                            }
                        ) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }.frame(maxWidth: 360)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                HStack {
                    Button("Prepare Reviewed Voices") { start(discover: false) }
                        .disabled(!canStart)
                    Button("Find Voices in Recordings") { start(discover: true) }
                        .disabled(!canStart)
                }
                Text("Recordings without voice examples need the Community-1 Speaker Diarization model.")
                    .font(.caption).foregroundStyle(.secondary)
                if let provider {
                    if let reason = VoiceLibraryPreparation.capability(for: provider).unavailableReason {
                        Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    else {
                        Text("Voice examples are processed on this Mac. Compatible prepared examples are reused.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                else {
                    Text("Choose a provider above. Add providers in Settings → Service Providers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.recordingID != nil {
                    Text("Finish the recording before preparing voice examples.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if let error {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red)
                }
                ForEach(Array(library.jobs.suffix(3).reversed())) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.providerName).font(.headline)
                            Text("\(job.progress) · \(stateTitle(job.state))").font(.caption).foregroundStyle(
                                .secondary)
                            if !job.failures.isEmpty {
                                DisclosureGroup("\(job.failures.count) Examples Need Attention") {
                                    ForEach(job.failures.keys.sorted(), id: \.self) { key in
                                        Text(job.failures[key] ?? "Couldn’t prepare this example.")
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.disclosureGroupStyle(AppDisclosureStyle())
                            }
                        }
                        Spacer()
                        if job.state == .running || job.state == .queued {
                            Button("Pause") { store.voicePreparation.pause(jobID: job.id) }
                        }
                        else if job.state == .paused || job.state == .failed || job.state == .cancelled {
                            Button(job.state == .paused ? "Resume" : "Retry") {
                                store.voicePreparation.resume(jobID: job.id, directory: { store.directory(for: $0) })
                            }.disabled(active || !store.libraryWritable || store.recordingID != nil)
                        }
                    }
                }
            }.padding(.top, 12)
        }
        .disclosureGroupStyle(AppDisclosureStyle())
        .onAppear {
            providerID =
                store.settings.serviceProviders.first { VoiceLibraryPreparation.capability(for: $0).isAvailable }?.id
        }
    }
    private var canStart: Bool {
        !loading && !active && store.libraryWritable && store.recordingID == nil
            && provider.map { VoiceLibraryPreparation.capability(for: $0).isAvailable } == true
    }
    private func stateTitle(_ state: VoicePreparationState) -> String {
        switch state {
        case .queued: return "Queued"
        case .running: return "Preparing"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    private func start(discover: Bool) {
        guard let provider else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let meetings = try await store.voicePreparationMeetings()
                store.voicePreparation.start(
                    provider: provider, meetings: meetings,
                    directory: { store.directory(for: $0) }, discover: discover)
                error = store.voicePreparation.errorMessage
            }
            catch { self.error = "Couldn’t load recordings. " + error.localizedDescription }
        }
    }
}

struct VoiceExamplePlaybackButton: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let example: VoiceExample
    var onSelect: (() -> Void)? = nil
    private var playing: Bool {
        guard let range = example.range else { return false }
        return playback.meetingID == example.meetingID
            && playback.excerptRanges == range.supportSpans.map { $0.start..<$0.end } && playback.isPlaying
            && playback.audioURL(forTrack: playback.selectedTrack)?.lastPathComponent == example.audioFile
    }
    private var available: Bool {
        guard example.isPlayable, store.voiceLibrary.audioIsCurrent(example), let file = example.audioFile else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: store.directory(for: example.meetingID).appendingPathComponent(file).path)
    }
    var body: some View {
        VoiceSamplePlaybackControl(playing: playing, available: available && !playback.isPlaybackBlocked) {
            if playing {
                playback.pause()
                return
            }
            playback.pause()
            onSelect?()
            playback.requestPlayback(
                load: {
                    guard await store.ensureMeetingLoaded(id: example.meetingID), !playback.isPlaybackBlocked,
                        let meeting = store.meeting(id: example.meetingID)
                    else { return nil }
                    return meeting
                },
                play: { meeting in
                    guard let range = example.range else { return }
                    playback.playExcerpts(
                        meeting: meeting, directory: store.directory(for: meeting.id), audioFile: range.audioFile,
                        spans: range.supportSpans)
                })
        }
    }
}
