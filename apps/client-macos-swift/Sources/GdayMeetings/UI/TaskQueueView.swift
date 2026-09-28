import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    var focusedTaskID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.largeTitle.bold())
                Spacer()
                Text(store.taskQueueSummary).foregroundStyle(.secondary)
            }
            if let error = store.managedTaskJournalError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if store.managedTasks.isEmpty && store.taskQueueOtherJobs.isEmpty {
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
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(store.tasksNewestFirst) { record in taskRow(record).id(record.id) }
                            if !store.taskQueueOtherJobs.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Other Activity").font(.headline)
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
        }.padding(24)
    }

    private func taskRow(_ record: ManagedTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if record.state == .running {
                    ProgressView().controlSize(.small).padding(.top, 3)
                }
                else {
                    Image(systemName: icon(record.state)).foregroundStyle(.secondary).padding(.top, 3)
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
                    Text(record.progress).font(.callout).textSelection(.enabled)
                    if let error = record.errorMessage, !error.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if record.recovery == .restartRequired {
                        Text("Restart sends the recording to the provider again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.attemptKey != nil && !record.state.isActive && record.state != .completed {
                        Text("Dismiss discards this saved request. The provider may continue processing it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.state == .running {
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
                    RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private func actions(_ record: ManagedTaskRecord) -> some View {
        if store.containsMeeting(id: record.meetingID) {
            Button("Open Meeting") { showMeeting(record.meetingID) }
        }
        if record.state == .queued || record.state == .running {
            if record.state == .queued {
                Button("Run Next") { store.prioritizeManagedTask(id: record.id) }
            }
            Button(record.state == .queued ? "Remove from Queue" : "Stop Waiting") {
                store.cancelManagedTask(id: record.id)
            }
        }
        if store.canRestartManagedTask(record) {
            Button("Restart") { store.restartManagedTask(id: record.id) }
        }
        if store.canRetryManagedTask(record) {
            Button(store.managedTaskActionTitle(record)) { store.retryManagedTask(id: record.id) }
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
        case .failed: "exclamationmark.circle"
        case .cancelled: "minus.circle"
        }
    }
}

struct TaskQueueStatusButton: View {
    @EnvironmentObject private var store: MeetingStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if store.managedTasks.contains(where: { $0.state == .running }) || !store.taskQueueOtherJobs.isEmpty {
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
    var showsTaskQueueStatus: Bool {
        managedTasks.contains { $0.state.isActive || $0.state == .failed } || !taskQueueOtherJobs.isEmpty
    }

    var taskQueueOtherJobs: [BackgroundJob] {
        backgroundJobs.filter { job in
            !managedTasks.contains { record in
                record.state.isActive && record.kind == job.key.kind && record.meetingID == job.meetingID
            }
        }
    }

    var taskQueueSummary: String {
        let running = managedTasks.filter { $0.state == .running }.count + taskQueueOtherJobs.count
        let queued = managedTasks.filter { $0.state == .queued }.count
        let failed = managedTasks.filter { $0.state == .failed }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if failed > 0 { parts.append(failed == 1 ? "1 needs attention" : "\(failed) need attention") }
        return parts.isEmpty ? "No active tasks" : parts.joined(separator: " · ")
    }
}

extension View {
    fileprivate func taskQueueCard() -> some View {
        self.background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}
