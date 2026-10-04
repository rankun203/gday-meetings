import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    var focusedTaskID: UUID? = nil
    @ViewState private var reviewingVoices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.title.weight(.semibold))
                Spacer()
                Text(store.taskQueueSummary)
                    .foregroundStyle(store.taskAttentionCount > 0 ? Color.accentColor : Color.secondary)
            }
            if let error = store.managedTaskJournalError {
                AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red)
            }
            if store.managedTasks.isEmpty && store.voiceLibrary.jobs.isEmpty && store.taskQueueOtherJobs.isEmpty {
                ContentUnavailableView(
                    "No Tasks", systemImage: "list.bullet.rectangle",
                    description: Text(
                        "Tasks appear here when you transcribe recordings, generate summaries, or run other background work."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                            if store.managedTasks.contains(where: { $0.state.isActive })
                                || !store.taskQueueOtherJobs.isEmpty
                                || store.voiceLibrary.jobs.contains(where: {
                                    $0.state == .running || $0.state == .queued
                                })
                            {
                                Text("Active Tasks").font(.headline)
                            }
                            ForEach(store.tasksNewestFirst.filter { $0.state.isActive }) { record in
                                taskRow(record).id(record.id)
                            }
                            ForEach(store.voiceTasksNewestFirst.filter { $0.state == .running || $0.state == .queued })
                            { job in
                                voiceTaskRow(job)
                            }
                            if !store.taskQueueOtherJobs.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(store.taskQueueOtherJobs) { job in
                                        HStack(spacing: 12) {
                                            ProgressView().controlSize(.small)
                                            Text(store.progressText(for: job)).frame(
                                                maxWidth: .infinity, alignment: .leading)
                                            if let id = job.meetingID {
                                                Button("Open Meeting") { showMeeting(id) }
                                            }
                                        }.padding(12).taskQueueCard()
                                    }
                                }
                            }

                            if store.taskAttentionCount > 0 {
                                Label("Needs Attention", systemImage: "exclamationmark.circle.fill").font(.headline)
                            }
                            ForEach(store.tasksNewestFirst.filter { $0.state == .failed }) { record in
                                taskRow(record).id(record.id)
                            }
                            ForEach(store.voiceTasksNewestFirst.filter { $0.state == .failed }) { job in
                                voiceTaskRow(job)
                            }
                            if store.voiceLibrary.jobs.contains(where: { $0.state == .paused }) {
                                Text("Paused").font(.headline)
                            }
                            ForEach(store.voiceTasksNewestFirst.filter { $0.state == .paused }) { job in
                                voiceTaskRow(job)
                            }
                            if store.managedTasks.contains(where: { $0.state == .completed || $0.state == .cancelled })
                                || store.voiceLibrary.jobs.contains(where: { $0.state == .completed })
                            {
                                Text("History").font(.headline)
                            }
                            ForEach(store.tasksNewestFirst.filter { $0.state == .completed || $0.state == .cancelled })
                            { record in taskRow(record).id(record.id) }
                            ForEach(store.voiceTasksNewestFirst.filter { $0.state == .completed }) { job in
                                voiceTaskRow(job)
                            }

                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: focusedTaskID) {
                        guard let focusedTaskID else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(focusedTaskID, anchor: .center)
                    }
                }
            }
        }.padding(AppTheme.contentInset)
            .sheet(isPresented: $reviewingVoices) {
                VoiceLibraryView(library: store.voiceLibrary).environmentObject(store)
            }
    }

    private func voiceTaskRow(_ job: VoicePreparationJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if job.state == .running { ProgressView().controlSize(.small) }
                Text(job.discover ? "Find Voices" : "Prepare Voice Library").font(.headline)
                Spacer()
                Text(job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text(job.providerName).font(.subheadline).foregroundStyle(.secondary)
            Text(job.progress).font(.callout)
            ForEach(Array(Set(job.failures.values)).sorted(), id: \.self) { failure in
                AppInlineMessage(text: failure, systemImage: "exclamationmark.circle", tint: .orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack { voiceTaskActions(job) }
                VStack(alignment: .leading, spacing: AppTheme.compactSpacing) { voiceTaskActions(job) }
            }
        }.padding(14).taskQueueCard().id(job.id)
    }

    @ViewBuilder private func voiceTaskActions(_ job: VoicePreparationJob) -> some View {
        if job.state == .running || job.state == .queued {
            Button("Pause") { store.voicePreparation.pause(jobID: job.id) }
        }
        if job.state == .paused || job.state == .failed {
            Button(job.state == .failed ? "Retry" : "Resume") {
                store.voicePreparation.resume(jobID: job.id, directory: { store.directory(for: $0) })
            }
            .disabled(
                !store.libraryWritable || store.recordingID != nil
                    || store.voiceLibrary.jobs.contains { $0.state == .running || $0.state == .queued })
        }
        Button("Open Voice Review") { reviewingVoices = true }
    }

    private func taskRow(_ record: ManagedTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if record.state == .running {
                    ProgressView().controlSize(.small).padding(.top, 3)
                }
                else {
                    Image(systemName: icon(record.state))
                        .foregroundStyle(record.state == .failed ? Color.accentColor : Color.secondary)
                        .padding(.top, 3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.meetingTitle).font(.headline).textSelection(.enabled)
                        Spacer()
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(
                                "Created " + record.createdAt.formatted(date: .complete, time: .shortened))
                    }
                    Text(operation(record.kind) + providerSuffix(record)).font(.subheadline).foregroundStyle(.secondary)
                    Text(record.progress).font(.callout)
                        .fontWeight(record.state == .failed ? .semibold : .regular)
                        .textSelection(.enabled)
                    if let error = record.errorMessage, !error.isEmpty {
                        Text(error).font(.callout).textSelection(.enabled)
                    }
                    if record.recovery == .restartRequired {
                        Text("Restart sends the recording to the provider again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.attemptKey != nil && !record.state.isActive && record.state != .completed {
                        Text("Dismiss discards this saved request. The provider may continue processing it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.state == .running && record.kind != .diarization {
                        Text("The provider may continue processing after you stop waiting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    actions(record)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) { actions(record) }
            }
        }.padding(14).taskQueueCard()
            .overlay {
                if record.id == focusedTaskID {
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private func actions(_ record: ManagedTaskRecord) -> some View {
        if store.canRestartManagedTask(record) {
            Button("Restart") { store.restartManagedTask(id: record.id) }
                .buttonStyle(.borderedProminent)
        }
        if store.canRetryManagedTask(record) {
            Button(store.managedTaskActionTitle(record)) { store.retryManagedTask(id: record.id) }
                .buttonStyle(.borderedProminent)
        }
        if store.containsMeeting(id: record.meetingID) {
            Button("Open Meeting") { showMeeting(record.meetingID) }
        }
        if record.state == .queued || record.state == .running {
            if record.state == .queued {
                Button("Run Next") { store.prioritizeManagedTask(id: record.id) }
            }
            Button(
                record.state == .queued ? "Remove from Queue" : record.kind == .diarization ? "Cancel" : "Stop Waiting"
            ) {
                store.cancelManagedTask(id: record.id)
            }
        }
        if !record.state.isActive {
            Button("Dismiss") { store.removeManagedTask(id: record.id) }
        }
    }

    private func providerSuffix(_ record: ManagedTaskRecord) -> String {
        if let name = record.providerName, !name.isEmpty { return " · " + name }
        guard let id = record.providerID,
            let provider = store.settings.serviceProviders.first(where: { $0.id == id })
        else { return "" }
        return " · " + provider.name
    }

    private func operation(_ kind: BackgroundJob.Kind) -> String {
        switch kind {
        case .transcription: "Transcription"
        case .summary: "Summary"
        case .diarization: "Speaker Labeling"
        case .chat, .contextChat: "Chat"
        case .archive: "Archive"
        case .importAudio: "Audio Import"
        default: "Other Task"
        }
    }

    private func icon(_ state: ManagedTaskState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }
}

struct TaskQueueStatusButton: View {
    @EnvironmentObject private var store: MeetingStore
    let action: () -> Void

    var body: some View {
        if store.taskAttentionCount > 0 {
            HStack(spacing: 12) {
                Label(
                    store.taskAttentionCount == 1
                        ? "1 Task Needs Attention" : "\(store.taskAttentionCount) Tasks Need Attention",
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                if !store.taskQueueActivitySummary.isEmpty {
                    Text(store.taskQueueActivitySummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(
                    store.taskAttentionCount == 1 ? "Review Task" : "Review \(store.taskAttentionCount) Tasks",
                    action: action
                )
                .buttonStyle(.borderedProminent)
                .help("Show tasks that need attention")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
        else {
            activityButton
        }
    }

    private var activityButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if store.managedTasks.contains(where: { $0.state == .running }) || !store.taskQueueOtherJobs.isEmpty
                    || store.voiceLibrary.jobs.contains(where: { $0.state == .running })
                {
                    ProgressView().controlSize(.small)
                }
                else {
                    Image(systemName: "list.bullet.rectangle")
                }
                Text(store.taskQueueSummary).font(.caption)
                Spacer()
                Text("Tasks").font(.caption)
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(.bar)
        .help("Show tasks").accessibilityLabel("Show Tasks: \(store.taskQueueSummary)")
    }
}

extension MeetingStore {
    var voiceTasksNewestFirst: [VoicePreparationJob] { voiceLibrary.jobs.sorted { $0.createdAt > $1.createdAt } }
    var taskAttentionCount: Int {
        managedTasks.filter { $0.state == .failed }.count + voiceLibrary.jobs.filter { $0.state == .failed }.count
    }

    var showsTaskQueueStatus: Bool {
        managedTasks.contains { $0.state.isActive || $0.state == .failed } || !taskQueueOtherJobs.isEmpty
            || voiceLibrary.jobs.contains { $0.state == .running || $0.state == .queued || $0.state == .failed }
    }

    var taskQueueOtherJobs: [BackgroundJob] {
        backgroundJobs.filter { job in
            job.key.kind.rawValue != "voiceLibrary"
                && !managedTasks.contains { record in
                    record.state.isActive && record.kind == job.key.kind && record.meetingID == job.meetingID
                }
        }
    }

    var taskQueueSummary: String {
        let failed = taskAttentionCount
        var parts = taskQueueActivitySummary.isEmpty ? [] : [taskQueueActivitySummary]
        if failed > 0 { parts.append(failed == 1 ? "1 needs attention" : "\(failed) need attention") }
        return parts.isEmpty ? "No active tasks" : parts.joined(separator: " · ")
    }

    var taskQueueActivitySummary: String {
        let running =
            managedTasks.filter { $0.state == .running }.count + taskQueueOtherJobs.count
            + voiceLibrary.jobs.filter { $0.state == .running }.count
        let queued =
            managedTasks.filter { $0.state == .queued }.count + voiceLibrary.jobs.filter { $0.state == .queued }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    fileprivate func taskQueueCard() -> some View {
        self.modifier(AppContentSurface())
    }
}
