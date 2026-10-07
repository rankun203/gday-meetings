import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    var focusedTaskID: UUID? = nil
    @ViewState private var reviewingVoices = false
    @ViewState private var discardedTask: ManagedTaskRecord?
    @ViewState private var discardedVoiceJob: VoicePreparationJob?
    @ViewState private var pendingRevisionRefresh: Task<Void, Never>?

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
        confirmationContent
            .sheet(isPresented: $reviewingVoices) {
                VoiceLibraryView(library: store.voiceLibrary).environmentObject(store)
            }
    }

    private var queueLayout: some View {
        HStack(spacing: 0) {
            taskListPane
            Divider()
            taskDetailPane
        }
    }

    private var lifecycleContent: some View {
        queueLayout
            .onAppear { if focusedTaskID == nil { refreshRows() } }
            .onDisappear {
                pendingRevisionRefresh?.cancel()
                pendingRevisionRefresh = nil
                session.cancelPageLoad()
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
            .onReceive(store.$managedTasks) { cached in
                let current = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                let updated = rows.map { row -> TaskHistoryRow in
                    if case .managed(let task) = row, let replacement = current[task.id] {
                        return .managed(replacement)
                    }
                    return row
                }
                if rows != updated { rows = updated }
            }
            .onReceive(store.voiceLibrary.$jobs) { cached in
                let current = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                let updated = rows.map { row -> TaskHistoryRow in
                    if case .voice(let job) = row, let replacement = current[job.id] { return .voice(replacement) }
                    return row
                }
                if rows != updated { rows = updated }
            }
    }

    private var observedContent: some View {
        lifecycleContent
            .onChange(of: store.managedTaskRevision) { _, _ in scheduleRevisionRefresh() }
            .onChange(of: store.settings.serviceProviders) { _, _ in refreshSelectedActions() }
            .onChange(of: store.meetingIndexRevision) { _, _ in refreshSelectedActions() }
            .onChange(of: store.recordingID) { _, _ in refreshSelectedActions() }
            .onChange(of: store.backgroundJobs.map(\.key)) { _, _ in refreshSelectedActions() }
            .onChange(
                of: store.voiceLibrary.jobs.map {
                    $0.id.uuidString + ":" + $0.state.rawValue + ":" + String($0.needsAttention)
                }
            ) { _, _ in
                refreshRows()
            }
            .onChange(of: selection) { _, id in if let row = rows.first(where: { $0.id == id }) { select(row) } }
    }

    private var focusedContent: some View {
        observedContent
            .task(id: focusedTaskID) { await revealFocusedTask() }
    }

    private var confirmationContent: some View {
        focusedContent
            .confirmationDialog(
                "Discard Task?",
                isPresented: Binding(
                    get: { discardedTask != nil }, set: { if !$0 { discardedTask = nil } }
                ), presenting: discardedTask
            ) { record in
                Button("Discard Task", role: .destructive) {
                    Task { await store.removeManagedTask(id: record.id) }
                    discardedTask = nil
                }
                Button("Keep Task", role: .cancel) { discardedTask = nil }
            } message: { record in
                let consequence =
                    record.attemptKey != nil || record.remoteJobID != nil
                    ? " The provider may continue processing its request." : " Recordings and results are kept."
                Text(
                    "Remove the saved " + record.operationTitle.lowercased() + " task for “" + record.meetingTitle
                        + "”?" + consequence)
            }
            .confirmationDialog(
                "Discard Task?",
                isPresented: Binding(
                    get: { discardedVoiceJob != nil }, set: { if !$0 { discardedVoiceJob = nil } }
                ), presenting: discardedVoiceJob
            ) { job in
                Button("Discard Task", role: .destructive) {
                    store.voicePreparation.discard(jobID: job.id)
                    discardedVoiceJob = nil
                    refreshRows()
                }
                Button("Keep Task", role: .cancel) { discardedVoiceJob = nil }
            } message: { _ in
                Text("Remove this saved task? Recordings and prepared voice examples are kept.")
            }
    }

    private var taskListPane: some View {
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
                if scope == .attention {
                    Button("Dismiss All Alerts") { Task { await store.dismissAllTaskAlerts() } }
                        .disabled(store.taskAttentionCount == 0)
                }
            }.padding(16)
            Divider()
            NativeTaskList(
                rows: rows, selection: $session.selection,
                recordingActive: store.recordingID != nil || store.isStartingRecording
                    || store.isFinalizingRecording, revealID: session.revealID,
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
        }.frame(width: 340)
    }

    private var taskDetailPane: some View {
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

    private func revealFocusedTask() async {
        guard let id = focusedTaskID, session.handledFocusID != id else { return }
        let token = session.beginFocusLoad(id)
        defer {
            if session.finishFocusLoad(token), !Task.isCancelled { refreshRows() }
        }
        guard let record = await store.loadManagedTask(id: id), !Task.isCancelled,
            focusedTaskID == id, generation == token
        else { return }
        if scope != .all {
            ignoresNextScopeChange = true
            scope = .all
        }
        select(.managed(record))
        let before = await store.taskHistoryPage(
            scope: .all, cursor: .init(createdAt: record.createdAt, id: record.id), newer: true, limit: 25)
        guard !Task.isCancelled, generation == token else { return }
        let after = await store.taskHistoryPage(
            scope: .all, cursor: .init(createdAt: record.createdAt, id: record.id), limit: 25)
        guard !Task.isCancelled, generation == token else { return }
        session.handledFocusID = id
        session.applyPage(before + [.managed(record)] + after, token: token)
        refreshSelectedActions()
        session.revealID = id
        session.revealToken = UUID()
        hasNewer = before.count == 25
        hasOlder = after.count == 25
    }

    private func select(_ row: TaskHistoryRow) {
        session.select(row)
        refreshSelectedActions()
    }
    private func refreshSelectedActions() {
        if case .managed(let record) = selectedRow {
            canRetry = store.canRetryManagedTask(record)
            canRestart = store.canRestartManagedTask(record)
            canOpen = store.containsMeeting(id: record.meetingID)
        }
        else {
            canRetry = false
            canRestart = false
            canOpen = false
        }
    }
    private func resetRows() {
        session.viewport.reset()
        session.revealID = nil
        session.resetPagePresentation()
        refreshSelectedActions()
        let requestedScope = scope
        let token = session.beginPageLoad()
        session.pageLoadTask = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            let page = await store.taskHistoryPage(scope: requestedScope)
            guard !Task.isCancelled, token == generation else { return }
            session.applyPage(page, token: token)
            refreshSelectedActions()
            hasOlder = page.count == 50
            hasNewer = false
        }
    }
    private func scheduleRevisionRefresh() {
        guard pendingRevisionRefresh == nil else { return }
        pendingRevisionRefresh = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            pendingRevisionRefresh = nil
            refreshRows()
        }
    }

    private func refreshRows() {
        guard !session.deferRefreshUntilFocusCompletes() else { return }
        guard let first = rows.first else {
            resetRows()
            return
        }
        let requestedScope = scope
        let token = session.beginPageLoad()
        let count = max(50, rows.count)
        session.pageLoadTask = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            let before = await store.taskHistoryPage(scope: requestedScope, cursor: first.cursor, newer: true, limit: 1)
            guard !Task.isCancelled, token == generation else { return }
            let page = await store.taskHistoryPage(scope: requestedScope, cursor: before.last?.cursor, limit: count)
            guard !Task.isCancelled, token == generation else { return }
            let previousPosition = rows.firstIndex { $0.id == selection } ?? 0
            session.applyPage(page, token: token, preferredPosition: previousPosition)
            refreshSelectedActions()
            hasOlder = page.count == count
            hasNewer = !before.isEmpty
        }
    }
    private func advance(newer: Bool) {
        guard !loadingPage, let edge = newer ? rows.first : rows.last else { return }
        let requestedScope = scope
        let token = session.beginPageLoad()
        session.pageLoadTask = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            let next = await store.taskHistoryPage(scope: requestedScope, cursor: edge.cursor, newer: newer)
            guard !Task.isCancelled, token == generation else { return }
            let overflow = max(0, rows.count + next.count - 150)
            if overflow > 0 {
                let removingVisible =
                    newer
                    ? visibleLast.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 >= rows.count - overflow }
                        == true
                    : visibleFirst.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 < overflow } == true
                if removingVisible { return }
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
        }
    }

    private func voiceTaskRow(_ job: VoicePreparationJob) -> some View {
        let failures = TaskFailurePage(failures: job.failures, offset: failureOffset)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                if job.state == .running { ProgressView().controlSize(.small) }
                Text(job.discover ? "Find Voices" : "Prepare Voice Library").font(.headline)
                Spacer()
                Text(job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text(job.providerName).font(.subheadline).foregroundStyle(.secondary)
            Text(job.progress).font(.callout)
            if job.state == .paused, let reason = job.timeline?.last?.reason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(voiceFailures(failures)) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title).font(.subheadline.weight(.semibold))
                    AppInlineMessage(text: failure.message, systemImage: "exclamationmark.circle", tint: .orange)
                    if let meetingID = failure.meetingID {
                        Button("Open Meeting") { showMeeting(meetingID) }
                    }
                }
            }
            if let timeline = job.timeline {
                TaskAttemptHistory(events: timeline)
            }
            if failures.count > TaskFailurePage.size {
                HStack {
                    Button("Previous Errors") { failureOffset = failures.offset - TaskFailurePage.size }
                        .disabled(!failures.hasPrevious)
                    Button("Next Errors") { failureOffset = failures.offset + TaskFailurePage.size }
                        .disabled(!failures.hasNext)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { voiceTaskActions(job) }
                VStack(alignment: .leading, spacing: AppTheme.compactSpacing) { voiceTaskActions(job) }
            }
        }.padding(14).taskQueueCard().id(job.id)
    }

    private struct VoiceFailure: Identifiable {
        let id: String
        let meetingID: UUID?
        let title: String
        let message: String
    }

    private func voiceFailures(_ page: TaskFailurePage) -> [VoiceFailure] {
        page.resolve { key, message in
            let recordingID = key.hasPrefix("recording-") ? UUID(uuidString: String(key.dropFirst(10))) : nil
            let exampleID = UUID(uuidString: key)
            let meetingID = recordingID ?? store.voiceLibrary.examples.first { $0.id == exampleID }?.meetingID
            let title =
                meetingID.flatMap { id in store.meetings.first { $0.id == id }?.title }
                ?? (recordingID == nil ? "Voice Example" : "Recording")
            return VoiceFailure(id: key, meetingID: meetingID, title: title, message: message)
        }
    }

    @ViewBuilder private func voiceTaskActions(_ job: VoicePreparationJob) -> some View {
        if job.state == .running || job.state == .queued {
            Button("Pause") { store.voicePreparation.pause(jobID: job.id) }
            Button("Cancel") { store.voicePreparation.cancel(jobID: job.id) }
        }
        if job.state == .paused || job.state == .failed || job.state == .cancelled {
            Button(job.state == .paused ? "Resume" : "Retry") {
                store.voicePreparation.resume(jobID: job.id, directory: { store.directory(for: $0) })
            }
            .disabled(
                !store.libraryWritable || store.recordingID != nil
                    || store.voiceLibrary.jobs.contains { $0.state == .running || $0.state == .queued })
        }
        if job.needsAttention {
            Button("Dismiss Alert") {
                store.voicePreparation.dismissAlert(jobID: job.id)
                refreshRows()
            }
        }
        if job.state != .running && job.state != .queued {
            Button("Discard Task", role: .destructive) { discardedVoiceJob = job }
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
                        Text(record.operationTitle).font(.headline).textSelection(.enabled)
                        Spacer()
                        Text(
                            (record.finishedAt ?? record.timeline?.last?.date ?? record.createdAt).formatted(
                                date: .abbreviated, time: .shortened)
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Last transition "
                                + (record.finishedAt ?? record.timeline?.last?.date ?? record.createdAt).formatted(
                                    date: .complete, time: .shortened))
                    }
                    Text(record.meetingTitle + providerSuffix(record)).font(.subheadline).foregroundStyle(.secondary)
                    Text(
                        [.searchIndex, .diarization].contains(record.kind) && record.state == .queued
                            && (store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording)
                            ? "Waiting for recording to finish" : record.progress
                    ).font(.callout)
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
                        Text("Discard Task removes this saved request. The provider may continue processing it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.state == .running && record.kind != .diarization && record.kind != .searchIndex {
                        Text("The provider may continue processing after you stop waiting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reason = record.attentionReason {
                Label(reason.title, systemImage: "exclamationmark.circle").font(.callout)
            }
            if let timeline = record.timeline { TaskAttemptHistory(events: timeline) }
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
        if record.state == .queued || record.state == .running || record.state == .paused {
            if record.state == .queued {
                Button("Run Next") { Task { await store.prioritizeManagedTask(id: record.id) } }
            }
            Button("Cancel") {
                Task { await store.cancelManagedTask(id: record.id) }
            }
        }
        if record.needsAttention {
            Button("Dismiss Alert") { Task { await store.dismissManagedTaskAlert(id: record.id) } }
                .help("Acknowledge the alert and keep the saved task")
        }
        if !record.state.isActive {
            Button("Discard Task", role: .destructive) { discardedTask = record }
        }
    }

    private func providerSuffix(_ record: ManagedTaskRecord) -> String {
        if let name = record.providerName, !name.isEmpty { return " · " + name }
        guard let id = record.providerID,
            let provider = store.settings.serviceProviders.first(where: { $0.id == id })
        else { return "" }
        return " · " + provider.name
    }

    private func icon(_ state: ManagedTaskState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
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
        managedTaskAttentionCount + managedTasks.filter { $0.isPreview && $0.needsAttention }.count
            + voiceLibrary.jobs.filter(\.needsAttention).count
    }

    var showsTaskQueueStatus: Bool {
        (managedTaskStateCounts[.queued, default: 0] + managedTaskStateCounts[.running, default: 0]
            + managedTaskAttentionCount > 0)
            || managedTasks.contains { $0.isPreview && ($0.state.isActive || $0.needsAttention) }
            || !taskQueueOtherJobs.isEmpty
            || voiceLibrary.jobs.contains { $0.state == .running || $0.state == .queued || $0.needsAttention }
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
        let indexQueued = managedMaintenanceStateCounts[.queued, default: 0]
        let maintenance =
            indexQueued + managedMaintenanceStateCounts[.running, default: 0]
            + managedMaintenanceStateCounts[.paused, default: 0] > 0
            || managedTasks.contains { $0.isPreview && $0.isMaintenance && ($0.state.isActive || $0.state == .paused) }
        let running =
            managedTasks.filter { $0.state == .running && !$0.isMaintenance }.count + taskQueueOtherJobs.count
            + voiceLibrary.jobs.filter { $0.state == .running }.count
        let queued =
            max(0, managedTaskStateCounts[.queued, default: 0] - indexQueued)
            + managedTasks.filter { $0.isPreview && $0.state == .queued && !$0.isMaintenance }.count
            + voiceLibrary.jobs.filter { $0.state == .queued }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if maintenance { parts.append("Search index maintenance") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    fileprivate func taskQueueCard() -> some View {
        self.modifier(AppContentSurface())
    }
}

private struct TaskAttemptHistory: View {
    let events: [TaskAttemptEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if events.last?.kind == .ended {
                timing(at: .now)
            }
            else {
                TimelineView(.periodic(from: .now, by: 1)) { context in timing(at: context.date) }
            }
            DisclosureGroup("Attempt History") {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.kind.title + " · " + event.date.formatted(date: .abbreviated, time: .standard))
                        if let reason = event.reason { Text(reason).foregroundStyle(.secondary) }
                    }.font(.caption).padding(.vertical, 4)
                }
            }.disclosureGroupStyle(AppDisclosureStyle())
        }
    }
    private func timing(at date: Date) -> some View {
        let timing = TaskTiming.measure(events, now: date)
        return Text(
            "Local active: " + TaskTiming.text(timing.active) + " · Waiting: " + TaskTiming.text(timing.waiting)
        )
        .font(.caption).foregroundStyle(.secondary)
    }
}
