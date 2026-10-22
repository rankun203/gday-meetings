import SwiftUI

/// Full-width scan summary. Preparation-only is available in Manage Samples.
struct VoicePreparationControls: View {
    @EnvironmentObject private var store: MeetingStore
    let library: VoiceLibraryStore
    var manageSamples: () -> Void = {}
    var showTask: (UUID) -> Void = { _ in }

    var body: some View {
        PeopleScanHost(store: store, library: library, manageSamples: manageSamples, showTask: showTask).equatable()
    }
}

private struct PeopleScanHost: View, Equatable {
    // Callbacks capture only stable store/dismiss actions. Keep changing row or
    // request values out of these closures when extending this host.
    static func == (left: Self, right: Self) -> Bool { left.store === right.store && left.library === right.library }
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    let store: MeetingStore
    let library: VoiceLibraryStore
    let manageSamples: () -> Void
    let showTask: (UUID) -> Void
    @StateObject private var observation: PeopleScanObservation
    @ViewState private var expanded = false
    @ViewState private var loading = false
    @ViewState private var request: UUID?
    @StateObject private var readiness = DiarizationReadiness()
    @ViewState private var healthRevision = UUID()
    @ViewState private var error: String?

    init(
        store: MeetingStore, library: VoiceLibraryStore, manageSamples: @escaping () -> Void,
        showTask: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.library = library
        self.manageSamples = manageSamples
        self.showTask = showTask
        _observation = StateObject(wrappedValue: PeopleScanObservation(store: store, library: library))
    }

    private struct HealthRequest: Equatable {
        let provider: ServiceProvider?
        let revision: UUID
    }
    private var healthRequest: HealthRequest { HealthRequest(provider: observation.provider, revision: healthRevision) }

    private var canStart: Bool {
        !loading && !observation.busy && observation.writable && !observation.recording
            && readiness.isReady(for: observation.provider)
            && observation.provider.map { VoiceLibraryPreparation.capability(for: $0).isAvailable } == true
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            details.padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Scan Recordings").font(.headline)
                if let scan = observation.presentation {
                    Text("· \(scan.status)").foregroundStyle(.secondary)
                    if scan.state == .running || scan.state == .queued {
                        Text(scan.progress).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    else {
                        Text(scan.date, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(
                            .secondary)
                    }
                }
                else {
                    Text("· Not Scanned").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.lineLimit(1)
        }
        .disclosureGroupStyle(AppDisclosureStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: healthRequest) { await checkReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            healthRevision = UUID()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider: \(observation.provider?.name ?? "Not Selected")")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Manage Samples…", action: manageSamples)
                Button("General Settings…") {
                    settingsTab = "general"
                    openSettings()
                }
            }
            if let scan = observation.presentation {
                HStack(alignment: .firstTextBaseline) {
                    Text(scan.status).font(.subheadline.bold())
                    Text(scan.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if scan.state == .running || scan.state == .queued {
                        Button("Pause Scan") { store.voicePreparation.pause(jobID: scan.jobID) }
                    }
                    Button("View Task") { showTask(scan.jobID) }
                }
                Text(scan.progress).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if scan.providerID != observation.provider?.id {
                    Text("This scan used \(scan.providerName).")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if scan.failureCount > 0 {
                    Text("\(scan.failureCount) \(scan.failureCount == 1 ? "item needs" : "items need") attention")
                        .font(.callout.bold())
                    ForEach(scan.failures) { failure in
                        Label(
                            failure.message + (failure.count > 1 ? " (\(failure.count) items)" : ""),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.callout).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary).help(failure.message)
                    }
                }
                HStack {
                    if scan.state != .running && scan.state != .queued {
                        if scan.state == .paused, let job = library.jobs.first(where: { $0.id == scan.jobID }),
                            PeopleScanPresentation.resumeUnavailableReason(for: job, provider: observation.provider)
                                == nil
                        {
                            Button("Resume Scan") {
                                guard canStart, let current = library.jobs.first(where: { $0.id == job.id }),
                                    PeopleScanPresentation.resumeUnavailableReason(
                                        for: current, provider: observation.provider) == nil
                                else { return }
                                store.voicePreparation.resume(
                                    jobID: current.id, directory: { store.directory(for: $0) })
                                error = store.voicePreparation.errorMessage
                            }.disabled(!canStart)
                        }
                        Button("Scan Again") { start() }.disabled(!canStart)
                    }
                    if loading { ProgressView().controlSize(.small) }
                }
                if scan.state == .paused, let job = library.jobs.first(where: { $0.id == scan.jobID }),
                    let reason = PeopleScanPresentation.resumeUnavailableReason(
                        for: job, provider: observation.provider)
                {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            else {
                HStack {
                    Text("No scan history.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Recordings") { start() }.disabled(!canStart)
                    if loading { ProgressView().controlSize(.small) }
                }
            }
            if !observation.writable {
                Text("This library is read-only.").font(.callout).foregroundStyle(.secondary)
            }
            if observation.recording {
                Text("Finish the recording before scanning.").font(.callout).foregroundStyle(.secondary)
            }
            if observation.provider?.kind.isLocalSpeaker != true,
                let reason = observation.provider.map({ VoiceLibraryPreparation.capability(for: $0).unavailableReason })
                    ?? "Choose a Speaker Diarization provider in General settings."
            {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if readiness.provider == observation.provider, let reason = readiness.result.reason,
                observation.provider?.kind.isLocalSpeaker == true
            {
                HStack {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Service Providers…") {
                        settingsTab = "providers"
                        openSettings()
                    }
                }
            }
            if let error { AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkReadiness() async {
        await readiness.refresh(provider: observation.provider, settings: store.settings)
    }

    private func start() {
        guard canStart, let provider = observation.provider else { return }
        let directory = store.dataDirectory
        let token = UUID()
        request = token
        loading = true
        error = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                guard request == token else { return }
                try await PeopleScanCommand.start(
                    store: store, library: library, provider: provider, directory: directory)
                error = store.voicePreparation.errorMessage
            }
            catch let failure { error = "Couldn’t load recordings. " + failure.localizedDescription }
        }
    }
}

/// Both scan entry points share capture checks and start exactly the same workflow.
@MainActor enum PeopleScanCommand {
    static func start(store: MeetingStore, library: VoiceLibraryStore, provider: ServiceProvider, directory: URL)
        async throws
    {
        let meetings = try await store.voicePreparationMeetings()
        guard !Task.isCancelled, store.voiceLibrary === library, store.dataDirectory == directory,
            store.settings.diarizationProviderID == provider.id,
            store.settings.serviceProviders.first(where: { $0.id == provider.id }) == provider,
            !library.jobs.contains(where: { $0.state == .running || $0.state == .queued }),
            store.libraryWritable, store.recordingID == nil, !store.isStartingRecording,
            !store.isFinalizingRecording
        else { return }
        store.voicePreparation.start(
            provider: provider, meetings: meetings, directory: { store.directory(for: $0) }, discover: true)
    }
}

/// The empty-review entry point owns readiness so opening the chooser is optional.
struct PeopleScanStartButton: View {
    let store: MeetingStore
    let library: VoiceLibraryStore
    let showTask: (UUID) -> Void
    @StateObject private var observation: PeopleScanObservation
    @StateObject private var readiness = DiarizationReadiness()
    @ViewState private var starting = false
    @ViewState private var error: String?
    init(store: MeetingStore, library: VoiceLibraryStore, showTask: @escaping (UUID) -> Void) {
        self.store = store
        self.library = library
        self.showTask = showTask
        _observation = StateObject(wrappedValue: PeopleScanObservation(store: store, library: library))
    }
    private var enabled: Bool {
        !starting && !observation.busy && observation.writable && !observation.recording
            && readiness.isReady(for: observation.provider)
    }
    var body: some View {
        Button("Scan Recordings") {
            guard enabled, let provider = observation.provider else { return }
            starting = true
            let directory = store.dataDirectory
            Task { @MainActor in
                defer { starting = false }
                do {
                    try await PeopleScanCommand.start(
                        store: store, library: library, provider: provider, directory: directory)
                    error = store.voicePreparation.errorMessage
                    if let job = PeopleScanPresentation.relevantJob(in: library.jobs),
                        job.state == .running || job.state == .queued
                    {
                        showTask(job.id)
                    }
                }
                catch { self.error = "Couldn’t load recordings. " + error.localizedDescription }
            }
        }.disabled(!enabled).fixedSize()
            .help(
                observation.recording
                    ? "Finish the recording before scanning."
                    : (readiness.result.reason ?? "Scan recordings using the provider selected in General settings.")
            )
            .task(id: observation.provider) {
                await readiness.refresh(provider: observation.provider, settings: store.settings)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await readiness.refresh(provider: observation.provider, settings: store.settings) }
            }
            .alert("Couldn’t Start Scan", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }))
        {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
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
    @ViewState private var audioSelection = VoiceReviewAudioSelection()
    private struct AudioSource: Equatable {
        let example: VoiceExample
        let directory: URL
    }
    private var source: AudioSource { AudioSource(example: example, directory: store.dataDirectory) }
    var body: some View {
        VoiceSamplePlaybackControl(playing: playing, available: audioSelection.available && !playback.isPlaybackBlocked)
        {
            if playing {
                playback.pause()
                return
            }
            playback.pause()
            onSelect?()
            guard let request = audioSelection.select(example, libraryDirectory: store.dataDirectory) else { return }
            playback.requestPlayback(
                load: {
                    let available = await request.verify()
                    guard audioSelection.complete(request, available: available), available,
                        store.dataDirectory == request.libraryDirectory,
                        await store.ensureMeetingLoaded(id: example.meetingID), !playback.isPlaybackBlocked,
                        audioSelection.request?.id == request.id,
                        let meeting = store.meeting(id: example.meetingID)
                    else { return nil }
                    return meeting
                },
                play: { meeting in
                    guard audioSelection.request?.id == request.id,
                        store.dataDirectory == request.libraryDirectory, let range = example.range
                    else { return }
                    playback.playExcerpts(
                        meeting: meeting, directory: store.directory(for: meeting.id), audioFile: range.audioFile,
                        spans: range.supportSpans)
                })
        }
        .task(id: source) {
            guard let request = audioSelection.select(example, libraryDirectory: store.dataDirectory) else { return }
            let available = await request.verify()
            guard !Task.isCancelled, source.example == request.example,
                source.directory == request.libraryDirectory
            else { return }
            audioSelection.complete(request, available: available)
        }
        .onDisappear { _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory) }
    }
}
