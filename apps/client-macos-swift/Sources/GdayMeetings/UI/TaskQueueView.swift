import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    var focusedTaskID: UUID? = nil
    @ViewState private var reviewingVoices = false

    @ObservedObject var session: TaskQueueSession
    private var scope: TaskHistoryScope {
        get { session.scope }
        nonmutating set { session.scope = newValue }
    }
    private var rows: [TaskHistoryRow] {
        get { session.rows }
        nonmutating set { session.rows = newValue }
    }
    private var selection: UUID? {
        get { session.selection }
        nonmutating set { session.selection = newValue }
    }
    private var selectedRow: TaskHistoryRow? {
        get { session.selectedRow }
        nonmutating set { session.selectedRow = newValue }
    }
    private var loadingPage: Bool {
        get { session.loadingPage }
        nonmutating set { session.loadingPage = newValue }
    }
    private var hasOlder: Bool {
        get { session.hasOlder }
        nonmutating set { session.hasOlder = newValue }
    }
    private var hasNewer: Bool {
        get { session.hasNewer }
        nonmutating set { session.hasNewer = newValue }
    }
    private var generation: UUID {
        get { session.generation }
        nonmutating set { session.generation = newValue }
    }
    private var canRetry: Bool {
        get { session.canRetry }
        nonmutating set { session.canRetry = newValue }
    }
    private var canRestart: Bool {
        get { session.canRestart }
        nonmutating set { session.canRestart = newValue }
    }
    private var canOpen: Bool {
        get { session.canOpen }
        nonmutating set { session.canOpen = newValue }
    }
    private var failureOffset: Int {
        get { session.failureOffset }
        nonmutating set { session.failureOffset = newValue }
    }
    private var selectedFailures: [String] {
        get { session.selectedFailures }
        nonmutating set { session.selectedFailures = newValue }
    }
    private var ignoresNextScopeChange: Bool {
        get { session.ignoresNextScopeChange }
        nonmutating set { session.ignoresNextScopeChange = newValue }
    }
    private var visibleFirst: UUID? {
        get { session.visibleFirst }
        nonmutating set { session.visibleFirst = newValue }
    }
    private var visibleLast: UUID? {
        get { session.visibleLast }
        nonmutating set { session.visibleLast = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Menu {
                        Picker("Show Tasks", selection: $session.scope) {
                            ForEach(TaskHistoryScope.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(scope.rawValue, systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }.padding(16)
                Divider()
                NativeTaskList(
                    rows: rows, selection: $session.selection, revealID: session.revealID,
                    revealToken: session.revealToken,
                    retainedViewport: session.viewport,
                    totalCount: !hasOlder && !loadingPage && !store.managedTasksLoading
                        && store.managedTaskJournalError == nil && !rows.isEmpty
                        ? store.taskHistoryCount(scope: scope) : nil
                ) { first, last, newer in
                    visibleFirst = first
                    visibleLast = last
                    guard !loadingPage else { return }
                    if newer, hasNewer, let index = rows.firstIndex(where: { $0.id == first }), index < 12 {
                        advance(newer: true)
                    }
                    else if !newer, hasOlder, let index = rows.firstIndex(where: { $0.id == last }),
                        index >= rows.count - 12
                    {
                        advance(newer: false)
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        if store.managedTasksLoading || loadingPage {
                            ProgressView("Loading Tasks…")
                        }
                        else {
                            Text("No tasks in this view").foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text(store.taskQueueSummary).font(.caption).foregroundStyle(.secondary).padding(12)
            }.frame(width: 290)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = store.managedTaskJournalError {
                        AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red)
                    }
                    if let selectedRow {
                        switch selectedRow {
                        case .managed(let saved): taskRow(store.managedTasks.first { $0.id == saved.id } ?? saved)
                        case .voice(let saved):
                            voiceTaskRow(store.voiceLibrary.jobs.first { $0.id == saved.id } ?? saved)
                        }
                    }
                    else {
                        ContentUnavailableView(
                            "Select a Task", systemImage: "list.bullet.rectangle",
                            description: Text("Review progress, results, and available actions.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                    ForEach(store.taskQueueOtherJobs) { job in
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(store.progressText(for: job))
                            if let id = job.meetingID { Button("Open Meeting") { showMeeting(id) } }
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if focusedTaskID == nil { refreshRows() } }
        .onDisappear {
            generation = UUID()
            loadingPage = false
            ignoresNextScopeChange = false
            session.handledFocusID = nil
        }
        .onChange(of: scope) { _, _ in
            if ignoresNextScopeChange {
                ignoresNextScopeChange = false
            }
            else {
                resetRows()
            }
        }
        .onChange(of: store.managedTaskRevision) { _, _ in refreshRows() }
        .onChange(of: store.settings.serviceProviders) { _, _ in refreshSelectedActions() }
        .onChange(of: store.meetingIndexRevision) { _, _ in refreshSelectedActions() }
        .onChange(of: store.recordingID) { _, _ in refreshSelectedActions() }
        .onChange(of: store.backgroundJobs.map(\.key)) { _, _ in refreshSelectedActions() }
        .onChange(of: store.voiceLibrary.jobs.map { $0.id.uuidString + ":" + $0.state.rawValue }) { _, _ in
            refreshRows()
        }
        .onChange(of: selection) { _, id in if let row = rows.first(where: { $0.id == id }) { select(row) } }
        .task(id: focusedTaskID) {
            guard let id = focusedTaskID, session.handledFocusID != id,
                let record = await store.loadManagedTask(id: id), !Task.isCancelled, focusedTaskID == id
            else {
                return
            }
            if scope != .all {
                ignoresNextScopeChange = true
                scope = .all
            }
            let token = UUID()
            generation = token
            loadingPage = true
            select(.managed(record))
            selection = id
            let before = await store.taskHistoryPage(
                scope: .all, cursor: .init(createdAt: record.createdAt, id: record.id), newer: true, limit: 25)
            guard !Task.isCancelled, generation == token else { return }
            let after = await store.taskHistoryPage(
                scope: .all, cursor: .init(createdAt: record.createdAt, id: record.id), limit: 25)
            guard !Task.isCancelled, generation == token else { return }
            session.handledFocusID = id
            rows = before + [.managed(record)] + after
            session.revealID = id
            session.revealToken = UUID()
            hasNewer = before.count == 25
            hasOlder = after.count == 25
            loadingPage = false
        }
        .sheet(isPresented: $reviewingVoices) { VoiceLibraryView(library: store.voiceLibrary).environmentObject(store) }
    }

    private func select(_ row: TaskHistoryRow) {
        if case .voice(let job) = row {
            let previousFailures: [String: String]?
            if case .voice(let previous) = selectedRow {
                previousFailures = previous.failures
            }
            else {
                previousFailures = nil
            }
            if previousFailures != job.failures { selectedFailures = Array(Set(job.failures.values)).sorted() }
        }
        if selectedRow?.id != row.id { failureOffset = 0 }
        selectedRow = row
        refreshSelectedActions()
    }
    private func refreshSelectedActions() {
        if case .managed(let record) = selectedRow {
            canRetry = store.canRetryManagedTask(record)
            canRestart = store.canRestartManagedTask(record)
            canOpen = store.containsMeeting(id: record.meetingID)
        }
    }
    private func resetRows() {
        session.viewport.reset()
        session.revealID = nil
        rows = []
        let token = UUID()
        generation = token
        loadingPage = true
        Task { @MainActor in
            let page = await store.taskHistoryPage(scope: scope)
            guard token == generation else { return }
            rows = page
            if selection == nil, let first = page.first {
                selection = first.id
                select(first)
            }
            hasOlder = page.count == 50
            hasNewer = false
            loadingPage = false
        }
    }
    private func refreshRows() {
        if let selectedRow {
            switch selectedRow {
            case .managed(let previous):
                Task {
                    let record = await store.loadManagedTask(id: previous.id)
                    guard self.selectedRow?.id == previous.id else { return }
                    if let record {
                        select(.managed(record))
                    }
                    else {
                        self.selectedRow = nil
                    }
                }
            case .voice(let previous):
                if let job = store.voiceLibrary.jobs.first(where: { $0.id == previous.id }) {
                    select(.voice(job))
                }
                else {
                    self.selectedRow = nil
                }
            }
        }
        guard let first = rows.first else {
            resetRows()
            return
        }
        let token = UUID()
        generation = token
        loadingPage = true
        let count = max(50, rows.count)
        Task { @MainActor in
            let before = await store.taskHistoryPage(scope: scope, cursor: first.cursor, newer: true, limit: 1)
            let page = await store.taskHistoryPage(scope: scope, cursor: before.last?.cursor, limit: count)
            guard token == generation else { return }
            rows = page
            hasOlder = page.count == count
            loadingPage = false
        }
    }
    private func advance(newer: Bool) {
        guard !loadingPage, let edge = newer ? rows.first : rows.last else { return }
        loadingPage = true
        let token = generation
        Task { @MainActor in
            let next = await store.taskHistoryPage(scope: scope, cursor: edge.cursor, newer: newer)
            guard token == generation else { return }
            let overflow = max(0, rows.count + next.count - 150)
            if overflow > 0 {
                let removingVisible =
                    newer
                    ? visibleLast.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 >= rows.count - overflow }
                        == true
                    : visibleFirst.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 < overflow } == true
                if removingVisible {
                    loadingPage = false
                    return
                }
            }
            if newer {
                rows = next + rows
                hasNewer = next.count == 50
            }
            else {
                rows += next
                hasOlder = next.count == 50
            }
            if rows.count > 150 {
                if newer {
                    rows.removeLast(rows.count - 150)
                    hasOlder = true
                }
                else {
                    rows.removeFirst(rows.count - 150)
                    hasNewer = true
                }
            }
            loadingPage = false
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
            ForEach(Array(selectedFailures.dropFirst(failureOffset).prefix(20)), id: \.self) { failure in
                AppInlineMessage(text: failure, systemImage: "exclamationmark.circle", tint: .orange)
            }
            if selectedFailures.count > 20 {
                HStack {
                    Button("Previous Errors") { failureOffset = max(0, failureOffset - 20) }
                        .disabled(failureOffset == 0)
                    Button("Next Errors") { failureOffset += 20 }
                        .disabled(failureOffset + 20 >= selectedFailures.count)
                }
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
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func actions(_ record: ManagedTaskRecord) -> some View {
        if canRestart {
            Button("Restart") { Task { await store.restartManagedTask(id: record.id) } }
                .buttonStyle(.borderedProminent)
        }
        if canRetry {
            Button(store.managedTaskActionTitle(record)) { Task { await store.retryManagedTask(id: record.id) } }
                .buttonStyle(.borderedProminent)
        }
        if canOpen {
            Button("Open Meeting") { showMeeting(record.meetingID) }
        }
        if record.state == .queued || record.state == .running {
            if record.state == .queued {
                Button("Run Next") { Task { await store.prioritizeManagedTask(id: record.id) } }
            }
            Button(
                record.state == .queued ? "Remove from Queue" : record.kind == .diarization ? "Cancel" : "Stop Waiting"
            ) {
                Task { await store.cancelManagedTask(id: record.id) }
            }
        }
        if !record.state.isActive {
            Button("Dismiss") { Task { await store.removeManagedTask(id: record.id) } }
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
        managedTaskStateCounts[.failed, default: 0] + managedTasks.filter { $0.isPreview && $0.state == .failed }.count
            + voiceLibrary.jobs.filter { $0.state == .failed }.count
    }

    var showsTaskQueueStatus: Bool {
        (managedTaskStateCounts[.queued, default: 0] + managedTaskStateCounts[.running, default: 0]
            + managedTaskStateCounts[.failed, default: 0] > 0)
            || managedTasks.contains { $0.isPreview && ($0.state.isActive || $0.state == .failed) }
            || !taskQueueOtherJobs.isEmpty
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
            managedTaskStateCounts[.queued, default: 0]
            + managedTasks.filter { $0.isPreview && $0.state == .queued }.count
            + voiceLibrary.jobs.filter { $0.state == .queued }.count
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
