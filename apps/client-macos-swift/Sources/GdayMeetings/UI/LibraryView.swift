import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LibrarySearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct NewMeetingNotesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newMeetingNotesAction: (() -> Void)? {
        get { self[NewMeetingNotesActionKey.self] }
        set { self[NewMeetingNotesActionKey.self] = newValue }
    }
    var librarySearchAction: (() -> Void)? {
        get { self[LibrarySearchActionKey.self] }
        set { self[LibrarySearchActionKey.self] = newValue }
    }
}

struct LibraryView: View {
    /// Splits after the first sentence; a single-sentence message has no body.
    static func alertParts(_ text: String?) -> (title: String, message: String) {
        let text = text ?? ""
        guard let end = text.range(of: ". ") else { return (text, "") }
        return (String(text[..<end.lowerBound]) + ".", String(text[end.upperBound...]))
    }
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @AppStorage("displaySummaryTitleOnMeetings") private var displaySummaryTitleOnMeetings = true
    @ViewState private var destination: LibraryDestination? = .meetings
    @ViewState private var focusedTaskID: UUID?
    @ViewState private var selectedMeeting: UUID?
    @ViewState private var meetingCountResult: (request: MeetingCountRequest, count: Int)?
    @ViewState private var selectedPeople: Set<UUID> = []
    @ViewState private var selectedTag: UUID?
    @ViewState private var search = ""
    @StateObject private var searchSession = LibrarySearchSession()
    @ViewState private var searchPreparationTask: Task<Void, Never>?
    @ViewState private var searchRequestID = UUID()
    @StateObject private var transcriptLayout = TranscriptLayoutService()
    @StateObject private var workspace = LibraryWorkspaceState()
    @ViewState private var showsSearchResults = false
    @ViewState private var openedSearchResult: SearchDisplayResult?
    @ViewState private var presentedSearchResult: SearchDisplayResult?
    @ViewState private var searchFocused = false
    @ViewState private var searchModelNotice: ServiceProvider?
    @ViewState private var promptedSearchModels: Set<String> = []
    @StateObject private var sidebarFocus = LibrarySidebarFocusRequest()
    @ViewState private var deleting: Meeting?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @ViewState private var sidebarTransition = UUID()
    private let sidebarControl: LibrarySidebarControl?

    init(sidebar: LibrarySidebarControl? = nil, selectedMeetingID: UUID? = nil) {
        sidebarControl = sidebar
        _selectedMeeting = ViewState(initialValue: selectedMeetingID)
    }

    private var recordingActive: Bool {
        store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording
    }
    private func showMeeting(_ id: UUID) {
        workspace.selectMeeting(id)
        showsSearchResults = false
        openedSearchResult = nil
        selectedMeeting = id
        destination = .meetings
    }

    private var filteredMeetings: [MeetingListEntry] { store.visibleMeetingEntries }

    private struct MeetingCountRequest: Equatable, Sendable {
        var revision: UUID
        var query: String
        var excludedTags: Set<UUID>
        var entries: [UUID]
        var reachedEnd: Bool
    }

    private var meetingCountRequest: MeetingCountRequest {
        .init(
            revision: store.meetingIndexRevision, query: store.meetingSearch, excludedTags: store.excludedTagIDs,
            entries: store.visibleMeetingIDs,
            reachedEnd: !store.hasMoreMeetings && !store.isLoadingMeetingPage && store.meetingPageError == nil)
    }

    private var meetingCount: Int? {
        guard let result = meetingCountResult, result.request == meetingCountRequest else { return nil }
        return result.count
    }

    private var emptyMeetings: some View {
        LibraryIndexPlaceholder(status: store.libraryDataStatus) { meetingsPlaceholder }
    }

    private var meetingsPlaceholder: some View {
        ContentUnavailableView("No Meetings", systemImage: "waveform")
    }

    private var createMeetingPlaceholder: some View {
        ContentUnavailableView {
            Label("Create a Meeting", systemImage: "waveform")
        } description: {
            Text("Start a recording, import audio or video, or create meeting notes.")
        } actions: {
            VStack(spacing: 8) {
                Button("New Recording…") { store.presentsRecordingSetup = true }
                    .disabled(!store.canStartRecording)
                    .buttonStyle(.borderedProminent)
                Button("Import Audio or Video…") { MeetingPanels.importAudio(store) }
                    .disabled(!canImportAudio)
                Button("New Meeting Notes", action: createMeetingNotes)
                    .disabled(!store.libraryWritable)
            }
        }
    }

    private var meetingList: some View {
        ZStack {
            NativeMeetingList(
                entries: filteredMeetings, selection: $selectedMeeting, revealID: store.latestCreatedMeetingID,
                recordingID: store.recordingID, isFinalizing: store.isFinalizingRecording,
                playingID: playback.meetingID, isPlaying: playback.isPlaying, canPlay: !recordingActive,
                archiveStatuses: store.archiveStatuses,
                displaySummaryTitle: displaySummaryTitleOnMeetings,
                viewportChanged: { store.prefetchMeetings($0) },
                play: { id in
                    playback.requestPlayback(
                        load: {
                            guard await store.ensureMeetingLoaded(id: id), !recordingActive,
                                let meeting = store.meeting(id: id)
                            else { return nil }
                            return meeting
                        },
                        play: { meeting in
                            let files = store.audioURLs(for: meeting)
                            if !files.isEmpty { playback.play(meeting: meeting, files: files) }
                        })
                },
                reveal: { id in NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)]) },
                export: { id in
                    Task {
                        guard await store.ensureMeetingLoaded(id: id), let meeting = store.meeting(id: id) else {
                            return
                        }
                        MeetingPanels.export(meeting, store: store)
                    }
                },
                delete: { id in
                    Task {
                        guard await store.ensureMeetingLoaded(id: id) else { return }
                        deleting = store.meeting(id: id)
                    }
                },
                retainedViewport: workspace.meetingViewport, totalCount: meetingCount
            )
            .scrollEdgeEffectStyle(.soft, for: .top)
            .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(AudioFileDrop())
        .task(id: meetingCountRequest) {
            let request = meetingCountRequest
            guard request.reachedEnd, !request.entries.isEmpty, let index = store.libraryIndex else { return }
            let count = await Task.detached(priority: .utility) {
                try? index.count(excludingTagIDs: request.excludedTags, query: request.query)
            }.value
            guard !Task.isCancelled, request == meetingCountRequest, let count else { return }
            meetingCountResult = (request, count)
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem(placement: .navigation) { addMeetingMenu }
        }
        .overlay {
            if store.isSearchingMeetings || (filteredMeetings.isEmpty && store.isLoadingMeetingPage) {
                ProgressView("Loading meetings…")
            }
            else if filteredMeetings.isEmpty && store.meetingPageError == nil {
                emptyMeetings
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.meetingPageError {
                VStack(alignment: .leading, spacing: 6) {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                    Button("Try Again") { Task { await store.searchMeetingPages("") } }
                }.padding(12).background(.regularMaterial)
            }
        }
        .onChange(of: store.latestCreatedMeetingID) { _, id in
            if let id, !store.visibleMeetingIDs.contains(id) { store.resetMeetingPages() }
        }
    }

    @ViewBuilder private var navigationWorkspace: some View {
        if showsSearchResults || destination == .tasks || destination == .agents {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                librarySidebar(twoColumn: true)
            } detail: {
                Group {
                    if showsSearchResults {
                        LibrarySearchResultsView(
                            session: searchSession,
                            open: openSearchResult, retry: retrySearch,
                            openPerson: { id in
                                workspace.people.query = ""
                                workspace.people.viewport.reset()
                                let person = store.people.first { $0.id == id }
                                if let person, !store.excludedTagIDs.isDisjoint(with: person.tagIDs) {
                                    workspace.people.showExcluded = true
                                }
                                workspace.people.refresh(
                                    index: store.directoryIndex, kind: .people, revision: store.directoryRevision)
                                workspace.people.page.reveal(id, query: "", expectedName: person?.name)
                                showsSearchResults = false
                                destination = .people
                                selectedPeople = [id]
                                search = ""
                            },
                            play: openSearchResult, navigate: navigateToSearchResult, selectMatch: playSearchResult,
                            canPlay: !recordingActive, index: store.libraryIndex
                        )
                        .onExitCommand {
                            showsSearchResults = false
                            search = ""
                        }
                    }
                    else if destination == .tasks {
                        TaskQueueView(showMeeting: showMeeting, focusedTaskID: focusedTaskID, session: workspace.tasks)
                    }
                    else {
                        AgentsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(showsSearchResults ? "Search Results" : destination == .tasks ? "Tasks" : "Agents")
            }
        }
        else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                librarySidebar(twoColumn: false)
            } content: {
                directoryColumn
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
            } detail: {
                selectedDetail
                    .frame(minWidth: AppTheme.minimumDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.readingBackground, ignoresSafeAreaEdges: [])
            }
        }
    }

    private func librarySidebar(twoColumn: Bool) -> some View {
        NativeLibrarySidebar(
            selection: Binding(
                get: { showsSearchResults ? nil : destination },
                set: { value in
                    if let value {
                        focusedTaskID = nil
                        showsSearchResults = false
                        openedSearchResult = nil
                        destination = value
                    }
                }),
            twoColumn: twoColumn, focusRequest: sidebarFocus
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    @ViewBuilder private var directoryColumn: some View {
        switch destination {
        case .people: PeopleView(selection: $selectedPeople, session: workspace.people)
        case .tags: TagsView(selection: $selectedTag, session: workspace.tags)
        default:
            meetingList
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        if destination == .meetings, let id = selectedMeeting {
            VStack(spacing: 0) {
                MeetingDetailView(
                    meetingID: id,
                    initialTranscriptRowID: openedSearchResult?.segmentID,
                    initialContentTab: searchContentTab,
                    usesWindowToolbar: true,
                    retainedTab: $workspace.meetingTab
                ).id(id)
            }
        }
        else if destination == .people, selectedPeople.count == 1,
            let id = selectedPeople.first,
            let person = store.people.first(where: { $0.id == id })
        {
            ContextDetailView(title: person.name, personID: id, tagID: nil).id(id)
        }
        else if destination == .people, selectedPeople.count > 1 {
            ContentUnavailableView {
                Label("\(selectedPeople.count) People Selected", systemImage: "person.2")
            } description: {
                Text("Choose Merge to combine the selected people.")
            }
        }
        else if destination == .tags, let id = selectedTag,
            let tag = store.tags.first(where: { $0.id == id })
        {
            ContextDetailView(title: tag.name, personID: nil, tagID: id).id(id)
        }
        else {
            LibraryIndexPlaceholder(
                status: store.libraryDataStatus,
                enabled: destination == .meetings && filteredMeetings.isEmpty,
                showsProgress: false
            ) { emptySelection }
        }
    }

    private var addMeetingMenu: some View {
        Menu {
            Button("New Meeting Recording…", systemImage: "record.circle") {
                store.presentsRecordingSetup = true
            }
            .disabled(!store.canStartRecording)
            Button("Import Audio or Video…", systemImage: "square.and.arrow.down") {
                MeetingPanels.importAudio(store)
            }
            .disabled(!canImportAudio)
            Button("New Meeting Notes", systemImage: "square.and.pencil", action: createMeetingNotes)
                .disabled(!store.libraryWritable)
        } label: {
            Label("Add Meeting", systemImage: "plus")
        }
        .help("Add Meeting")
    }

    private var canImportAudio: Bool {
        store.libraryWritable && !recordingActive && !store.isImportingAudio
    }

    private func createMeetingNotes() {
        let previousMeeting = selectedMeeting
        let previousDestination = destination
        Task {
            let id = await store.createMeeting(title: "Untitled Meeting")
            guard store.meeting(id: id) != nil, selectedMeeting == previousMeeting,
                destination == previousDestination
            else { return }
            showMeeting(id)
            workspace.meetingTab = 1
        }
    }

    private var recordingActionTitle: String {
        if store.isFinalizingRecording { return "Saving Recording…" }
        if store.isStartingRecording { return "Starting Recording…" }
        return store.recordingID != nil ? "Show Recording" : "New Recording…"
    }

    private var recordButton: some View {
        Button {
            if let id = store.recordingID {
                showMeeting(id)
            }
            else {
                store.presentsRecordingSetup = true
            }
        } label: {
            Label(
                recordingActionTitle,
                systemImage: store.isFinalizingRecording
                    ? "hourglass.circle.fill"
                    : recordingActive ? "waveform.circle.fill" : "record.circle.fill"
            )
            .modifier(RecordingToolbarForeground())
        }
        .labelStyle(.iconOnly).tint(.red)
        .help(recordingActionTitle)
        .disabled(
            store.isStartingRecording || store.isFinalizingRecording
                || (store.recordingID == nil && !store.canStartRecording))
    }

    private var showsMeetingTabs: Bool {
        selectedMeeting != nil
    }

    @ToolbarContentBuilder private var meetingToolbar: some ToolbarContent {
        if !showsSearchResults && openedSearchResult != nil && (destination != .meetings || !showsMeetingTabs) {
            ToolbarItem(placement: .navigation) {
                backToSearchResultsButton
            }
        }
        if !showsSearchResults && destination == .meetings {
            if showsMeetingTabs {
                ToolbarItemGroup(placement: .principal) {
                    if openedSearchResult != nil {
                        backToSearchResultsButton
                    }
                    MeetingContentTabs(selection: $workspace.meetingTab)
                }
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
    }

    private var backToSearchResultsButton: some View {
        Button("Back to Search Results", systemImage: "chevron.left") {
            showsSearchResults = true
            search = searchSession.query
        }.help("Back to Search Results").keyboardShortcut("[", modifiers: .command)
    }

    @ToolbarContentBuilder private var recordingToolbar: some ToolbarContent {
        // The API is back-deployed to macOS 26.1 but declared only by the Xcode 27 SDK.
        #if compiler(>=6.4)
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { recordButton }
                    .visibilityPriority(.high)
            }
            else {
                ToolbarItem(placement: .primaryAction) { recordButton }
            }
        #else
            ToolbarItem(placement: .primaryAction) { recordButton }
        #endif
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "library-search", placement: .primaryAction) {
            LibrarySearchField(
                controller: store.localSearch, text: $search, focused: $searchFocused,
                activate: activateLibrarySearch,
                submit: submitSearch)
        }
    }

    var body: some View {
        // HIG: a sidebar expresses the hierarchy; an intermediate list selects content.
        // Native columns align their titles and actions with the window toolbar.
        // https://developer.apple.com/design/human-interface-guidelines/sidebars
        VStack(spacing: 0) {
            navigationWorkspace
                .navigationSplitViewStyle(.balanced)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .toolbar {
                    meetingToolbar
                    recordingToolbar
                }
            // HIG Feedback: keep the activity visible while people browse other content.
            // A single persistent transport replaces scattered status and action rows.
            // https://developer.apple.com/design/human-interface-guidelines/feedback
            // Allocate actual layout height so detail overlays cannot extend beneath playback.
            VStack(spacing: 0) {
                if recordingActive
                    && (store.isStartingRecording || showsSearchResults || destination != .meetings
                        || selectedMeeting != store.recordingID)
                {
                    recordingStrip
                }
                else if playback.hasSelection && !recordingActive {
                    MeetingPlayerBar(showMeeting: showMeeting)
                }
                VStack(spacing: 0) {
                    if store.showsTaskQueueStatus {
                        TaskQueueStatusButton {
                            workspace.tasks.scope = store.taskAttentionCount > 0 ? .attention : .active
                            workspace.tasks.selection = nil
                            workspace.tasks.selectedRow = nil
                            focusedTaskID = nil
                            showsSearchResults = false
                            openedSearchResult = nil
                            destination = .tasks
                        }
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: store.showsTaskQueueStatus)
            }
        }
        .environment(\.transcriptLayoutService, transcriptLayout)
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .sheet(isPresented: $store.presentsRecordingSetup) {
            RecordingSetupView(onStarted: showMeeting).environmentObject(store)
        }
        .sheet(item: $presentedSearchResult) { result in
            MeetingDetailSheet(
                meetingID: result.meetingID,
                initialTranscriptRowID: result.segmentID,
                initialContentTab: searchContentTab(for: result)
            ) { presentedSearchResult = nil }
        }
        .background(PlaybackSpaceKey(playback: playback))
        .focusedSceneValue(\.librarySearchAction, focusLibrarySearch)
        .focusedSceneValue(\.newMeetingNotesAction, createMeetingNotes)
        .environment(\.showManagedTask) { id in
            focusedTaskID = id
            showsSearchResults = false
            openedSearchResult = nil
            destination = .tasks
        }
        .task {
            searchSession.updatePeople(store.people.map { .init(id: $0.id, name: $0.name) })
            store.searchConfigurationChanged()
        }
        .onChange(of: store.people) { previous, people in
            let records = people.map { PeopleNameRecord(id: $0.id, name: $0.name) }
            guard records != previous.map({ PeopleNameRecord(id: $0.id, name: $0.name) }) else { return }
            let preparesProviders = showsSearchResults && searchSession.mode != .text && !searchSession.query.isEmpty
            searchSession.updatePeople(records, refreshSearch: !preparesProviders)
            if preparesProviders { submitSearch(searchSession.query) }
        }
        .onAppear {
            workspace.selectMeeting(selectedMeeting)
            sidebarControl?.connect(
                expanded: sidebarExpandedBinding, rows: sidebarExpandedBinding, toggle: toggleSidebar(reduceMotion:))
        }
        .onChange(of: selectedMeeting) { _, id in
            workspace.selectMeeting(id)
            if openedSearchResult?.meetingID != id { openedSearchResult = nil }
        }
        .onChange(of: showsSearchResults ? nil : destination) { _, selection in
            // The navigation owner observes current intent; a departing native
            // column can still receive its old selection during replacement.
            sidebarFocus.cancelIfDestinationChanged(to: selection)
        }
        .onDisappear { sidebarControl?.disconnect() }
        .onChange(of: search) { _, query in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let provider = store.selectedSearchProvider
            {
                store.localSearch.typingBegan(provider)
            }
            if query.isEmpty, showsSearchResults { showsSearchResults = false }
        }
        .onChange(of: store.recordingID) { _, id in if let id { showMeeting(id) } }
        .alert(
            "Download a Search Model",
            isPresented: Binding(
                get: { searchModelNotice != nil },
                set: { if !$0 { searchModelNotice = nil } }),
            presenting: searchModelNotice
        ) { provider in
            Button("Open Local Search Settings") {
                searchFocused = false
                ProviderHealthStore.shared.settingsProviderID = provider.id
                settingsTab = "providers"
                openSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text(
                "Searching by meaning requires downloading \((provider.localSearch ?? .init()).selectedModel.title). Open Local Search settings to download the model or install it manually."
            )
        }
        // Messages lead with the problem; that sentence is the title, and what was
        // kept and technical detail follow as the smaller message text.
        .alert(
            Self.alertParts(store.errorMessage).title,
            isPresented: Binding(
                get: { store.errorMessage != nil && !store.presentsRecordingSetup },
                set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(Self.alertParts(store.errorMessage).message)
        }
        .alert(
            store.recordingPermissionNeeded?.title ?? "Recording Access Needed",
            isPresented: Binding(
                get: { store.recordingPermissionNeeded != nil && !store.presentsRecordingSetup },
                set: { if !$0 { store.recordingPermissionNeeded = nil } })
        ) {
            Button("Request Access Again") {
                store.recordingPermissionNeeded = nil
                store.presentsRecordingSetup = true
            }
            Button("Cancel", role: .cancel) { store.recordingPermissionNeeded = nil }
        } message: {
            Text(
                (store.recordingPermissionNeeded?.explanation ?? "")
                    + " If macOS asks you to relaunch, reopen the app before recording. macOS may not show another prompt for an existing permission decision."
            )
        }
        .alert(
            "Move “\(deleting?.title ?? "meeting")” to Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { meeting in
            Button("Move to Trash", role: .destructive) {
                deleting = nil
                Task {
                    if await store.deleteMeeting(id: meeting.id) {
                        transcriptLayout.remove(meetingID: meeting.id)
                        if selectedMeeting == meeting.id { selectedMeeting = nil }
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { deleting = nil }
                .keyboardShortcut(.cancelAction)
        } message: { _ in
            Text("The meeting and its saved files will be moved to the Trash. You can restore them in Finder.")
        }
    }

    private var searchContentTab: MeetingContentTab? {
        searchContentTab(for: openedSearchResult)
    }

    private func searchContentTab(for result: SearchDisplayResult?) -> MeetingContentTab? {
        switch result?.passage?.kind {
        case .notes: .notes
        case .summary: .summary
        case .transcript: .transcript
        default: nil
        }
    }

    private func submitSearch() { submitSearch(search) }

    private func submitSearch(_ submittedQuery: String) {
        let query = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchPreparationTask?.cancel()
        let requestID = UUID()
        searchRequestID = requestID
        searchSession.updatePeople(store.people.map { .init(id: $0.id, name: $0.name) })
        showsSearchResults = true
        openedSearchResult = nil
        searchFocused = false
        searchSession.beginPreparation(query, mode: .semantic)
        let exclusions = store.excludedTagIDs
        searchPreparationTask = Task {
            await searchSession.waitForPeopleResolution()
            guard !Task.isCancelled, searchRequestID == requestID else { return }
            if searchSession.contentQuery.isEmpty {
                searchSession.finishPeopleOnly()
                return
            }
            guard let configured = store.selectedSearchProvider else {
                searchSession.preparationFailed("Choose a Search provider in General settings.")
                return
            }
            do {
                let provider = try await store.localSearch.prepare(configured)
                guard !Task.isCancelled, searchRequestID == requestID else { return }
                let providers: [any SearchProvider] = [provider]
                _ = searchSession.submit(query, mode: .semantic, providers: providers, excludingTagIDs: exclusions)
            }
            catch {
                guard !Task.isCancelled, searchRequestID == requestID else { return }
                searchSession.preparationFailed(error.localizedDescription)
            }
        }
    }

    private func retrySearch() {
        if searchSession.usesRankedSearch {
            search = searchSession.query
            submitSearch()
            return
        }
        if searchSession.results.isEmpty {
            search = searchSession.query
            submitSearch()
        }
        else {
            searchSession.retry()
        }
    }

    private func playSearchResult(_ result: SearchDisplayResult) {
        guard !recordingActive, let start = result.playbackStart else { return }
        playback.requestPlayback(
            load: {
                guard await store.ensureMeetingLoaded(id: result.meetingID), !recordingActive else { return nil }
                return store.meeting(id: result.meetingID)
            },
            play: { meeting in
                let files = store.audioURLs(for: meeting)
                if !files.isEmpty { playback.play(meeting: meeting, files: files, at: start) }
            })
    }

    private func openSearchResult(_ result: SearchDisplayResult) {
        presentedSearchResult = result
        playSearchResult(result)
    }

    private func navigateToSearchResult(_ result: SearchDisplayResult) {
        workspace.selectMeeting(result.meetingID)
        selectedMeeting = result.meetingID
        destination = .meetings
        openedSearchResult = result
        showsSearchResults = false
        playSearchResult(result)
    }

    private func activateLibrarySearch() {
        guard let provider = store.selectedSearchProvider else { return }
        Task { @MainActor in
            let model = (provider.localSearch ?? .init()).selectedModel
            let manager = LocalModelManager.shared
            let health = await manager.health(for: model.localID)
            guard store.selectedSearchProvider == provider else { return }
            if health.isReady {
                return
            }
            guard ![.downloading, .verifying, .preparing].contains(manager.state(for: model.localID).phase) else {
                return
            }
            let key = provider.id.uuidString + ":" + model.space
            guard promptedSearchModels.insert(key).inserted else { return }
            searchModelNotice = provider
        }
    }

    private func focusLibrarySearch() {
        searchFocused = true
    }

    private var sidebarExpanded: Bool { columnVisibility == .all }
    private var sidebarExpandedBinding: Binding<Bool> {
        Binding(get: { sidebarExpanded }, set: { columnVisibility = $0 ? .all : .doubleColumn })
    }
    private var twoColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarExpanded ? .all : .detailOnly },
            set: { columnVisibility = $0 == .detailOnly ? .doubleColumn : .all })
    }

    private func toggleSidebar(reduceMotion: Bool) {
        let transition = UUID()
        sidebarTransition = transition
        withAnimation(reduceMotion ? nil : .default, completionCriteria: .removed) {
            columnVisibility = sidebarExpanded ? .doubleColumn : .all
        } completion: {
            guard sidebarTransition == transition else { return }
            sidebarControl?.completed?(sidebarExpanded)
        }
    }

    @ViewBuilder private var emptySelection: some View {
        if destination == .people {
            ContentUnavailableView(
                "Select a Person", systemImage: "person.crop.circle",
                description: Text("Choose a person to see their meetings and profile."))
        }
        else if destination == .tags {
            ContentUnavailableView(
                "Select a Tag", systemImage: "tag", description: Text("Choose a tag to see its meetings."))
        }
        else if filteredMeetings.isEmpty && !store.isLoadingMeetingPage && store.meetingPageError == nil {
            createMeetingPlaceholder
        }
        else {
            ContentUnavailableView {
                Label("G’day", systemImage: "waveform")
            } description: {
                Text("No meeting is selected.")
            } actions: {
                Button("New Recording…") { store.presentsRecordingSetup = true }
                    .disabled(!store.canStartRecording)
            }
        }
    }

    private var recordingStrip: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                RecordingStripTitle(showMeeting: showMeeting)
                if let started = store.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let elapsed =
                            store.isFinalizingRecording
                            ? (store.meetings.first { $0.id == store.recordingID }?.duration ?? 0)
                            : timeline.date.timeIntervalSince(started)
                        Text(playbackTime(elapsed)).font(.title3).monospacedDigit().accessibilityLabel(
                            "Recording duration \(playbackTime(elapsed))")
                    }
                }
                Spacer(minLength: 12)
                if let id = store.recordingID {
                    Button("Show Recording") { showMeeting(id) }
                    Button("Stop & Save", systemImage: "stop.fill") { Task { await store.stopRecording() } }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(store.isFinalizingRecording)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(.bar)
    }
}

@MainActor
enum MeetingPanels {
    static func followLogs(_ store: MeetingStore) {
        Task {
            do { try await LogFollow.open() }
            catch { store.errorMessage = "Couldn’t follow logs. \(error.localizedDescription)" }
        }
    }

    /// Help → Export Logs and Settings → Data Privacy: saves the last hour of this
    /// run's capture and network entries as a text file and shows it in Finder.
    /// No audio, meeting text, or credentials are included.
    static func exportLogs(_ store: MeetingStore) {
        let start = Date().addingTimeInterval(-3600)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LogExport.export(since: start, to: LogExport.directory)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            catch {
                store.errorMessage = "Couldn’t export logs. \(error.localizedDescription)"
            }
        }
    }

    static func importAudio(_ store: MeetingStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie] + ["opus", "ogg"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                do { _ = try await store.importAudioFiles(urls) }
                catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        }
    }
    static func importLegacy(_ store: MeetingStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import Library"
        panel.message =
            "Choose your existing Gday Meetings data folder. Meetings and audio are copied into the Swift app."
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { _ = try await store.importLegacyLibrary(url: url) }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
    }
    static func importArchive(_ store: MeetingStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await store.importArchive(url: url) }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
    }
    static func export(_ meeting: Meeting, store: MeetingStore) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title + ".json"
        let formats = MeetingExportPanel(panel: panel)
        if withExtendedLifetime(formats, { panel.runModal() }) == .OK, let url = panel.url {
            Task {
                do { try await store.exportMeeting(id: meeting.id, to: url) }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
    }
}

/// Native toolbar tint does not always color its label. Preserve the system's
/// disabled rendering by applying a foreground only to enabled content.
private struct RecordingToolbarForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(.red)
        }
        else {
            content
        }
    }
}

/// Observe progress locally so an indexing counter does not redraw the meeting list.
private struct LibraryIndexPlaceholder<Content: View>: View {
    @ObservedObject var status: LibraryDataStatus
    var enabled = true
    var showsProgress = true
    let content: Content

    init(
        status: LibraryDataStatus, enabled: Bool = true, showsProgress: Bool = true, @ViewBuilder content: () -> Content
    ) {
        self.status = status
        self.enabled = enabled
        self.showsProgress = showsProgress
        self.content = content()
    }

    var body: some View {
        if enabled && status.isBuilding {
            VStack(spacing: 12) {
                if showsProgress {
                    ProgressView().controlSize(.large)
                    Text("Building Index").font(.headline)
                    if status.isDiscovering {
                        Text("\(status.discoveredFolders.formatted()) meeting folders checked")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    else if status.processed > 0 {
                        Text("\(status.processed.formatted()) meetings processed")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    else {
                        Text("Reading meeting folders…").foregroundStyle(.secondary)
                    }
                }
                else {
                    Text("Meetings will appear as they are indexed.")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        else {
            content
        }
    }
}
