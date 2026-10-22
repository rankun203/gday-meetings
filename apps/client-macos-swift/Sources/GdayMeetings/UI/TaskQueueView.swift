import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    var focusedTaskID: UUID? = nil
    var focusedTaskRequest: UUID? = nil
    var sidebarExpanded = false
    @ViewState private var reviewingVoices = false
    @ViewState private var discardedTask: ManagedTaskRecord?
    @ViewState private var discardedVoiceJob: VoicePreparationJob?
    @ViewState private var voiceActionErrorID: UUID?
    @ViewState private var voiceActionError: String?
    @ViewState private var pendingRevisionRefresh: Task<Void, Never>?
    @ViewState private var filterCounts: [TaskHistoryQuery: Int] = [:]
    private struct FilterCountKey: Hashable {
        struct Voice: Hashable {
            let id: UUID
            let state: String
            let discover: Bool
            let attention: Bool
        }
        let directory: URL
        let managed: Int
        let voices: [Voice]
        let visibility: String
        let library: UUID?
    }
    private var filterCountKey: FilterCountKey {
        .init(
            directory: store.dataDirectory, managed: store.managedTaskFilterCountRevision,
            voices: store.voiceLibrary.jobs.map {
                .init(id: $0.id, state: $0.state.rawValue, discover: $0.discover, attention: $0.needsAttention)
            }, visibility: store.taskVisibilityPredicate,
            library: store.excludedTagIDs.isEmpty ? nil : store.meetingIndexRevision)
    }
    private func countedTitle(_ title: String, query: TaskHistoryQuery) -> String {
        filterCounts[query].map { "\(title) (\($0))" } ?? title
    }

    @ObservedObject var session: TaskQueueSession
    private var scope: TaskHistoryScope {
        get { session.scope }
        nonmutating set { session.scope = newValue }
    }
    private var query: TaskHistoryQuery { session.query }
    private struct VoicePageRevision: Equatable {
        let id: UUID
        let state: VoicePreparationState
        let activityAt: Date
        let attention: Bool
    }
    private struct DisplayRevision: Equatable {
        let managed: Int
        let voices: [VoicePageRevision]
        let library: UUID?
        let excludedTags: Set<UUID>
        let meetingTags: [TaskVisibilityCache.MeetingTags]
    }
    private func voicePageRevisions(for query: TaskHistoryQuery) -> [VoicePageRevision] {
        store.voiceLibrary.jobs.filter(query.includes).map {
            .init(id: $0.id, state: $0.state, activityAt: $0.taskHistoryActivityAt, attention: $0.needsAttention)
        }
    }
    private func displayRevision(for query: TaskHistoryQuery) -> DisplayRevision {
        .init(
            managed: store.managedTaskDisplayRevisions[query, default: 0], voices: voicePageRevisions(for: query),
            library: store.excludedTagIDs.isEmpty ? nil : store.meetingIndexRevision,
            excludedTags: store.excludedTagIDs,
            meetingTags: store.excludedTagIDs.isEmpty ? [] : store.meetings.map { .init(id: $0.id, tags: $0.tagIDs) })
    }
    private func pageIsCurrent(_ revision: DisplayRevision, query requested: TaskHistoryQuery) -> Bool {
        let current = displayRevision(for: requested)
        return query == requested && revision.library == current.library
            && revision.excludedTags == current.excludedTags && revision.meetingTags == current.meetingTags
    }
    private func refreshChangedData(_ revision: DisplayRevision, query requested: TaskHistoryQuery) {
        let current = displayRevision(for: requested)
        if revision.managed != current.managed || revision.voices != current.voices { scheduleRevisionRefresh() }
    }
    private var filterTitle: String {
        session.taskType == .all ? scope.rawValue : session.taskType.rawValue
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
                PeopleMatchReviewLauncher(library: store.voiceLibrary).environmentObject(store)
            }
    }

    private var queueLayout: some View {
        GeometryReader { geometry in
            HSplitView {
                taskListPane
                    .frame(minWidth: 250, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)
                    .background(
                        ListWidthPersistence(key: .init(page: .tasks, sidebarExpanded: sidebarExpanded)))
                taskDetailPane
                    .frame(minWidth: AppTheme.minimumDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 250 + 1 + AppTheme.minimumDetailWidth)
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
            .onChange(of: query) { _, _ in
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
                if rows != updated {
                    rows = updated
                    if let selected = updated.first(where: { $0.id == selection }) { session.select(selected) }
                }
            }
            .onReceive(store.voiceLibrary.$jobs) { cached in
                let current = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                let updated = rows.map { row -> TaskHistoryRow in
                    if case .voice(let job) = row, let replacement = current[job.id] { return .voice(replacement) }
                    return row
                }
                if rows != updated {
                    rows = updated
                    if let selected = updated.first(where: { $0.id == selection }) { session.select(selected) }
                }
            }
    }

    private var observedContent: some View {
        lifecycleContent
            .onChange(of: store.managedTaskDisplayRevisions[query, default: 0]) { _, _ in scheduleRevisionRefresh() }
            .onChange(of: store.settings.serviceProviders) { _, _ in refreshSelectedActions() }
            .onChange(of: store.meetingIndexRevision) { _, _ in refreshTaskVisibility() }
            .onChange(of: store.excludedTagIDs) { _, _ in refreshTaskVisibility() }
            .onChange(of: store.recordingID) { _, _ in refreshSelectedActions() }
            .onChange(of: store.backgroundJobs.map(\.key)) { _, _ in refreshSelectedActions() }
            .onChange(of: voicePageRevisions(for: query)) { _, _ in
                scheduleRevisionRefresh()
            }
            .onChange(of: selection) { _, id in if let row = rows.first(where: { $0.id == id }) { select(row) } }
    }

    private var focusedContent: some View {
        observedContent
            .task(id: filterCountKey) {
                let key = filterCountKey
                do {
                    let result = try await store.taskFilterCounts()
                    guard !Task.isCancelled, filterCountKey == key else { return }
                    filterCounts = result
                }
                catch {
                    guard !Task.isCancelled, filterCountKey == key else { return }
                    filterCounts = [:]
                    store.managedTaskJournalError = "Couldn’t count tasks. \(error.localizedDescription)"
                }
            }
            .task(id: focusedTaskRequest ?? focusedTaskID) {
                session.receiveFocusRequest(focusedTaskRequest)
                await revealFocusedTask()
            }
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
                    Picker("Filter Tasks", selection: $session.filter) {
                        Section("Status") {
                            ForEach(TaskHistoryScope.allCases.filter { $0 != .maintenance }) { status in
                                Text(countedTitle(status.rawValue, query: .init(status: status)))
                                    .tag(TaskHistoryQuery(status: status))
                            }
                        }
                        Section("Type") {
                            ForEach(TaskHistoryType.menuCases) { type in
                                Text(countedTitle(type.rawValue, query: .init(type: type)))
                                    .tag(TaskHistoryQuery(type: type))
                            }
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).help(filterTitle)
                Spacer()
                if scope == .attention && session.totalCount > 0 {
                    Button("Dismiss Alerts") {
                        Task { await store.dismissAllTaskAlerts() }
                    }
                    .fixedSize()
                }
            }.padding(16)
            Divider()
            NativeTaskList(
                rows: rows, selection: $session.selection,
                recordingActive: store.recordingID != nil || store.isStartingRecording
                    || store.isFinalizingRecording, revealID: session.revealID,
                revealToken: session.revealToken,
                retainedViewport: session.viewport,
                totalCount: session.footerCount(
                    total: session.totalCount, historyLoading: store.managedTasksLoading,
                    hasHistoryError: store.managedTaskJournalError != nil)
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
                        VStack(spacing: 12) {
                            Text(
                                store.hasTaskHistory
                                    ? (session.taskType == .all ? scope.emptyMessage : "No tasks of this type")
                                    : "No tasks yet"
                            )
                            .foregroundStyle(.secondary)
                            if (scope != .all || session.taskType != .all) && store.hasTaskHistory {
                                Button("Show All Tasks") { session.showAllTasks() }
                            }
                        }
                        .multilineTextAlignment(.center)
                        .padding(16)
                    }
                }
            }
            Divider()
            Text(store.taskQueueSummary).font(.caption).foregroundStyle(.secondary).padding(12)
        }
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(store.progressText(for: job))
                            if let id = job.meetingID { Button("Open Meeting") { showMeeting(id) } }
                        }
                        TaskProgressView(progress: job.progressDetails ?? TaskProgress(phase: job.progress))
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
        let voice = store.voiceLibrary.jobs.contains { $0.id == id }
        let record = voice ? nil : await store.loadManagedTask(id: id)
        guard !Task.isCancelled, generation == token, focusedTaskID == id else { return }
        guard voice || record.map({ store.isTaskMeetingVisible($0.meetingID) }) == true else {
            _ = session.finishFocusLoad(token)
            refreshRows()
            return
        }
        if scope != .all || session.taskType != .all {
            ignoresNextScopeChange = true
            session.showAllTasks()
        }
        session.handledFocusID = id
        resetRows(revealing: id)
    }

    private func select(_ row: TaskHistoryRow) {
        session.select(row)
        refreshSelectedActions()
    }
    private func refreshTaskVisibility() {
        if case .managed(let record) = selectedRow, !store.isTaskMeetingVisible(record.meetingID) {
            session.selection = nil
            session.selectedRow = nil
        }
        rows.removeAll { row in
            if case .managed(let record) = row { return !store.isTaskMeetingVisible(record.meetingID) }
            return false
        }
        refreshSelectedActions()
        scheduleRevisionRefresh()
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
    private func currentRow(id: UUID) -> TaskHistoryRow? {
        if let job = store.voiceLibrary.jobs.first(where: { $0.id == id }) { return .voice(job) }
        if let record = store.managedTask(id: id) { return .managed(record) }
        return nil
    }
    private func includesCurrentRow(_ row: TaskHistoryRow, query: TaskHistoryQuery) -> Bool {
        switch row {
        case .managed(let record): query.includes(record) && store.isTaskMeetingVisible(record.meetingID)
        case .voice(let job): query.includes(job)
        }
    }
    private func retainedSelection(
        outside page: [TaskHistoryRow], previous: TaskHistoryRow?, query requested: TaskHistoryQuery
    ) async -> TaskHistoryRow? {
        guard let id = selection, !page.contains(where: { $0.id == id }) else { return nil }
        if let current = currentRow(id: id) {
            return includesCurrentRow(current, query: requested) ? current : nil
        }
        guard case .managed(let saved) = previous, saved.id == id,
            let current = await store.loadManagedTask(id: id)
        else { return nil }
        let row = TaskHistoryRow.managed(current)
        return includesCurrentRow(row, query: requested) ? row : nil
    }
    private func resetRows(revealing id: UUID? = nil) {
        let target = id.flatMap { currentRow(id: $0) }
        let previousSelection = target ?? selectedRow
        session.viewport.reset()
        session.revealID = nil
        session.resetPagePresentation()
        refreshSelectedActions()
        let requestedQuery = query
        if let target, includesCurrentRow(target, query: requestedQuery) { session.select(target) }
        let token = id.map { session.beginFocusLoad($0) } ?? session.beginPageLoad()
        session.pageLoadTask = Task { @MainActor in
            defer {
                if id != nil {
                    if session.finishFocusLoad(token), !Task.isCancelled { refreshRows() }
                }
                else {
                    session.finishPageLoad(token)
                }
            }
            let revision = displayRevision(for: requestedQuery)
            let page: [TaskHistoryRow]
            let total: Int
            let newerAvailable: Bool
            let olderAvailable: Bool
            if let target, includesCurrentRow(target, query: requestedQuery) {
                let prepared = await session.loadStableReveal(
                    target: target, token: token,
                    currentTarget: {
                        guard query == requestedQuery, let current = currentRow(id: target.id),
                            includesCurrentRow(current, query: requestedQuery)
                        else {
                            return nil
                        }
                        return current
                    },
                    load: { requested -> (before: [TaskHistoryRow], after: [TaskHistoryRow], total: Int)? in
                        let before = await store.taskDisplayPage(
                            scope: requestedQuery.status, type: requestedQuery.type,
                            cursor: requested.displayCursor, newer: true, limit: 25)
                        guard !Task.isCancelled, token == generation else { return nil }
                        let after = await store.taskDisplayPage(
                            scope: requestedQuery.status, type: requestedQuery.type,
                            cursor: requested.displayCursor, limit: 25)
                        guard !Task.isCancelled, token == generation else { return nil }
                        let total = await store.taskDisplayCount(
                            scope: requestedQuery.status, type: requestedQuery.type)
                        return (before, after, total)
                    })
                guard !Task.isCancelled, token == generation else { return }
                guard query == requestedQuery else { return }
                guard let prepared, let loaded = prepared.page else {
                    // A moving or removed target must not keep a focus load alive.
                    // An ordinary page preserves valid details without another reveal retry.
                    resetRows()
                    return
                }
                var seen = Set<UUID>()
                page = (loaded.before + [prepared.target] + loaded.after).filter { seen.insert($0.id).inserted }
                total = loaded.total
                newerAvailable = loaded.before.count == 25
                olderAvailable = loaded.after.count == 25
            }
            else {
                page = await store.taskDisplayPage(scope: requestedQuery.status, type: requestedQuery.type)
                guard !Task.isCancelled, token == generation else { return }
                total = await store.taskDisplayCount(scope: requestedQuery.status, type: requestedQuery.type)
                newerAvailable = false
                olderAvailable = page.count == 50
            }
            guard !Task.isCancelled, token == generation else { return }
            let selectionAtRead = selection
            let retained = await retainedSelection(outside: page, previous: previousSelection, query: requestedQuery)
            guard !Task.isCancelled, token == generation else { return }
            guard pageIsCurrent(revision, query: requestedQuery), selection == selectionAtRead else {
                scheduleRevisionRefresh()
                return
            }
            session.totalCount = total
            session.applyPage(page, token: token, retainingSelection: retained)
            if let id, selection == id, let revealed = page.first(where: { $0.id == id }) {
                session.select(revealed)
                session.revealID = id
                session.revealToken = UUID()
            }
            refreshSelectedActions()
            hasOlder = olderAvailable
            hasNewer = newerAvailable
            refreshChangedData(revision, query: requestedQuery)
        }
    }
    private func scheduleRevisionRefresh() {
        guard pendingRevisionRefresh == nil else { return }
        pendingRevisionRefresh = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            pendingRevisionRefresh = nil
            session.refreshWhenIdle { refreshRows() }
        }
    }

    private func refreshRows() {
        guard !session.deferRefreshUntilFocusCompletes() else { return }
        guard let firstCursor = session.firstDisplayCursor ?? rows.first?.displayCursor else {
            resetRows()
            return
        }
        let requestedQuery = query
        let wasAtNewestPage = !hasNewer
        let token = session.beginPageLoad()
        let count = max(50, rows.count)
        session.pageLoadTask = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            let revision = displayRevision(for: requestedQuery)
            let before =
                wasAtNewestPage
                ? []
                : await store.taskDisplayPage(
                    scope: requestedQuery.status, type: requestedQuery.type,
                    cursor: firstCursor, newer: true, limit: 1)
            guard !Task.isCancelled, token == generation else { return }
            let page = await store.taskDisplayPage(
                scope: requestedQuery.status, type: requestedQuery.type, cursor: before.last?.displayCursor,
                limit: count)
            let total = await store.taskDisplayCount(scope: requestedQuery.status, type: requestedQuery.type)
            guard !Task.isCancelled, token == generation else { return }
            let selectionAtRead = selection
            let retained = await retainedSelection(outside: page, previous: selectedRow, query: requestedQuery)
            guard !Task.isCancelled, token == generation else { return }
            guard pageIsCurrent(revision, query: requestedQuery), selection == selectionAtRead else {
                scheduleRevisionRefresh()
                return
            }
            let revealNewest =
                wasAtNewestPage
                && page.first?.id != rows.first?.id
                && (session.viewport.anchor.map {
                    $0.id == rows.first?.id && $0.offset <= 0.5
                } ?? true)
            if let retained, session.hasMovedSinceDisplay(retained) {
                resetRows(revealing: retained.id)
                return
            }
            session.totalCount = total
            let previousPosition = rows.firstIndex { $0.id == selection } ?? 0
            session.applyPage(page, token: token, preferredPosition: previousPosition, retainingSelection: retained)
            if revealNewest, let newest = page.first {
                session.revealID = newest.id
                session.revealToken = UUID()
            }
            refreshSelectedActions()
            hasOlder = page.count == count
            hasNewer = !before.isEmpty
            refreshChangedData(revision, query: requestedQuery)
        }
    }
    private func advance(newer: Bool) {
        guard !loadingPage,
            let cursor = newer ? session.firstDisplayCursor : session.lastDisplayCursor
        else { return }
        let requestedQuery = query
        let token = session.beginPageLoad()
        session.pageLoadTask = Task { @MainActor in
            defer { session.finishPageLoad(token) }
            let revision = displayRevision(for: requestedQuery)
            let next = await store.taskDisplayPage(
                scope: requestedQuery.status, type: requestedQuery.type, cursor: cursor, newer: newer)
            guard !Task.isCancelled, token == generation else { return }
            guard pageIsCurrent(revision, query: requestedQuery) else {
                scheduleRevisionRefresh()
                return
            }
            guard
                let merged = TaskQueueSession.mergePage(
                    next, into: rows, newer: newer, visibleFirst: visibleFirst, visibleLast: visibleLast)
            else {
                refreshChangedData(revision, query: requestedQuery)
                return
            }
            let incomingIDs = Set(next.map(\.id))
            let overflow = Set(rows.map(\.id)).union(incomingIDs).count > 150
            if newer {
                hasNewer = next.count == 50
                if overflow { hasOlder = true }
            }
            else {
                hasOlder = next.count == 50
                if overflow { hasNewer = true }
            }
            session.replacePageRows(merged, retainingCursors: true, replacingCursors: incomingIDs)
            // Advance through the queried range even when a transitioned row was
            // already retained, so a page of duplicates cannot stall navigation.
            session.advanceDisplayCursor(newer ? next.first?.displayCursor : next.last?.displayCursor, newer: newer)
            refreshChangedData(revision, query: requestedQuery)
        }
    }

    private func voiceTaskRow(_ job: VoicePreparationJob) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                if job.state == .running { ProgressView().controlSize(.small) }
                Text(job.operationTitle).font(.headline)
                Spacer()
                Text(job.outcomeTitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(job.providerName).font(.subheadline).foregroundStyle(.secondary)
            Text(job.progress).font(.callout)
            if job.state == .running {
                TaskProgressView(progress: job.progressDetails)
            }
            if job.state == .paused, let reason = job.timeline?.last?.reason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if [.paused, .failed, .cancelled].contains(job.state), let reason = voiceTaskResumeReason(job) {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if voiceActionErrorID == job.id, let voiceActionError {
                AppInlineMessage(text: voiceActionError, systemImage: "exclamationmark.triangle", tint: .red)
            }
            if !job.failures.isEmpty {
                VoicePreparationFailures(
                    jobID: job.id, failures: job.failures, offset: $session.failureOffset, showMeeting: showMeeting)
            }
            if let timeline = job.timeline {
                TaskAttemptHistory(events: timeline)
            }
            ViewThatFits(in: .horizontal) {
                HStack { voiceTaskActions(job) }
                VStack(alignment: .leading, spacing: AppTheme.compactSpacing) { voiceTaskActions(job) }
            }
        }.padding(14).taskQueueCard().id(job.id)
    }

    private func pauseAndReveal(_ job: VoicePreparationJob) {
        store.voicePreparation.pause(jobID: job.id)
        guard let paused = store.voiceLibrary.jobs.first(where: { $0.id == job.id }), paused.state == .paused else {
            return
        }
        pendingRevisionRefresh?.cancel()
        pendingRevisionRefresh = nil
        if !query.includes(paused) {
            ignoresNextScopeChange = true
            scope = .paused
        }
        resetRows(revealing: job.id)
    }

    private func actAndReveal(id: UUID, operation: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            guard let reveal = await session.performTaskAction(id: id, operation: operation) else { return }
            if reveal, let row = currentRow(id: id), includesCurrentRow(row, query: query) {
                pendingRevisionRefresh?.cancel()
                pendingRevisionRefresh = nil
                resetRows(revealing: id)
            }
            else {
                refreshRows()
            }
        }
    }

    private func voiceTaskResumeReason(_ job: VoicePreparationJob) -> String? {
        PeopleScanPresentation.resumeUnavailableReason(
            for: job, provider: store.settings.serviceProviders.first { $0.id == store.settings.diarizationProviderID })
    }

    @ViewBuilder private func voiceTaskActions(_ job: VoicePreparationJob) -> some View {
        if job.state == .running || job.state == .queued {
            Button("Pause") { pauseAndReveal(job) }
            Button("Cancel") { actAndReveal(id: job.id) { store.voicePreparation.cancel(jobID: job.id) } }
        }
        if job.state == .paused || job.state == .failed || job.state == .cancelled, voiceTaskResumeReason(job) == nil {
            Button(job.state == .paused ? "Resume" : "Retry") {
                voiceActionErrorID = job.id
                voiceActionError = nil
                actAndReveal(id: job.id) {
                    guard let current = store.voiceLibrary.jobs.first(where: { $0.id == job.id }),
                        voiceTaskResumeReason(current) == nil
                    else { return }
                    store.voicePreparation.resume(jobID: job.id, directory: { store.directory(for: $0) })
                    voiceActionError = store.voicePreparation.errorMessage
                }
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
                            record.taskHistoryActivityAt.formatted(
                                date: .abbreviated, time: .shortened)
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Last transition "
                                + record.taskHistoryActivityAt.formatted(
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
                    if record.state == .running {
                        TaskProgressView(progress: record.progressDetails ?? TaskProgress(phase: record.progress))
                    }
                    if let error = record.errorMessage, !error.isEmpty, error != record.progress {
                        Text(error).font(.callout).textSelection(.enabled)
                    }
                    if record.recovery == .restartRequired {
                        Text("Restart sends the recording to the provider again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.attemptKey != nil && !record.state.isActive && record.state != .completed
                        && record.providerID != ThisMacProvider.id
                    {
                        Text("Discard Task removes this saved request. The provider may continue processing it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if record.state == .running && [.transcription, .summary].contains(record.kind)
                        && record.providerID != ThisMacProvider.id
                    {
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
            Button("Restart") { actAndReveal(id: record.id) { await store.restartManagedTask(id: record.id) } }
                .buttonStyle(.borderedProminent)
        }
        if canRetry {
            Button(store.managedTaskActionTitle(record)) {
                actAndReveal(id: record.id) { await store.retryManagedTask(id: record.id) }
            }
            .buttonStyle(.borderedProminent)
        }
        if canOpen {
            Button("Open Meeting") { showMeeting(record.meetingID) }
        }
        if record.kind != .recordingFinalization
            && (record.state == .queued || record.state == .running || record.state == .paused)
        {
            if record.state == .queued {
                Button("Run Next") { Task { await store.prioritizeManagedTask(id: record.id) } }
            }
            Button("Cancel") {
                actAndReveal(id: record.id) { await store.cancelManagedTask(id: record.id) }
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
                if store.visibleSearchMaintenanceBatchActive
                    || store.visibleManagedTasks.contains(where: { $0.state == .running })
                    || !store.taskQueueOtherJobs.isEmpty
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
    var hasTaskHistory: Bool {
        taskHistoryCount(scope: .all) > 0
    }

    var voiceTasksNewestFirst: [VoicePreparationJob] { voiceLibrary.jobs.sorted { $0.createdAt > $1.createdAt } }
    var taskAttentionCount: Int {
        visibleManagedTaskCount(where: "attention=1", unfiltered: managedTaskAttentionCount)
            + visibleManagedTasks.filter { $0.isPreview && $0.needsAttention }.count
            + voiceLibrary.jobs.filter(\.needsAttention).count
    }

    var visibleSearchMaintenanceBatchActive: Bool {
        searchMaintenanceBatchActive && (excludedTagIDs.isEmpty || localSearch.scanTask != nil)
    }

    var showsTaskQueueStatus: Bool {
        visibleManagedTaskCount(
            where: "state IN ('queued','running') OR attention=1",
            unfiltered: managedTaskStateCounts[.queued, default: 0] + managedTaskStateCounts[.running, default: 0]
                + managedTaskAttentionCount) > 0
            || visibleManagedTasks.contains { $0.isPreview && ($0.state.isActive || $0.needsAttention) }
            || visibleSearchMaintenanceBatchActive
            || !taskQueueOtherJobs.isEmpty
            || voiceLibrary.jobs.contains { $0.state == .running || $0.state == .queued || $0.needsAttention }
    }

    var taskQueueOtherJobs: [BackgroundJob] {
        backgroundJobs.filter { job in
            (job.meetingID.map(isTaskMeetingVisible) ?? true) && job.key.kind.rawValue != "voiceLibrary"
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
        let maintenance =
            visibleSearchMaintenanceBatchActive
            || visibleManagedTaskCount(
                where: "kind='searchIndex' AND automatic=1 AND state IN ('queued','running','paused')",
                unfiltered: [.queued, .running, .paused].reduce(0) {
                    $0 + managedMaintenanceStateCounts[$1, default: 0]
                }) > 0
            || visibleManagedTasks.contains {
                $0.isPreview && $0.isMaintenance && ($0.state.isActive || $0.state == .paused)
            }
        let running =
            visibleManagedTasks.filter { $0.state == .running && !$0.isMaintenance }.count + taskQueueOtherJobs.count
            + voiceLibrary.jobs.filter { $0.state == .running }.count
        let queued =
            visibleManagedTaskCount(
                where: "state='queued' AND (kind!='searchIndex' OR automatic=0)",
                unfiltered: max(
                    0, managedTaskStateCounts[.queued, default: 0] - managedMaintenanceStateCounts[.queued, default: 0])
            )
            + visibleManagedTasks.filter { $0.isPreview && $0.state == .queued && !$0.isMaintenance }.count
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
