import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LibrarySearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
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
    @StateObject private var workspace = LibraryWorkspaceState()
    @ViewState private var showsSearchResults = false
    @ViewState private var openedSearchResult: SearchDisplayResult?
    @FocusState private var searchFocused: Bool
    @StateObject private var sidebarFocus = LibrarySidebarFocusRequest()
    @ViewState private var deleting: Meeting?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @ViewState private var searchPresented = false
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
        ContentUnavailableView {
            Label("No Meetings", systemImage: "waveform")
        } description: {
            Text("Record a meeting or import audio to get started.")
        } actions: {
            Button("New Recording") { store.presentsRecordingSetup = true }
                .disabled(!store.canStartRecording)
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
                            session: searchSession, mode: searchModeBinding,
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
                            }
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
                if openedSearchResult != nil {
                    HStack {
                        Button("Back to Search Results", systemImage: "chevron.left") {
                            showsSearchResults = true
                            search = searchSession.query
                        }
                        Spacer()
                        if let audio = openedSearchResult?.audio {
                            Text("Voice match · \(playbackTime(audio.start))")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Play Match", systemImage: "play.fill") {
                                playback.requestPlayback(
                                    load: {
                                        guard await store.ensureMeetingLoaded(id: id) else { return nil }
                                        return store.meeting(id: id)
                                    },
                                    play: { meeting in
                                        playback.playExcerpt(
                                            meeting: meeting, directory: store.directory(for: id),
                                            audioFile: audio.filename, start: audio.start,
                                            end: audio.start + audio.duration)
                                    })
                            }
                            .disabled(store.recordingID != nil)
                        }
                    }.padding(.horizontal, AppTheme.contentInset).padding(
                        .top, AppTheme.contentSpacing)
                }
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
            Group {
                Button("New Meeting Notes", systemImage: "square.and.pencil") {
                    let previousMeeting = selectedMeeting
                    let previousDestination = destination
                    Task {
                        let id = await store.createMeeting(title: "Untitled Meeting")
                        guard store.meeting(id: id) != nil, selectedMeeting == previousMeeting,
                            destination == previousDestination
                        else { return }
                        showMeeting(id)
                    }
                }
                Button("Import Audio or Video…", systemImage: "square.and.arrow.down") {
                    MeetingPanels.importAudio(store)
                }
                .disabled(recordingActive || store.isImportingAudio)
                Divider()
                Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }
                Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }
            }.disabled(!store.libraryWritable)
            Divider()
            Button("Open Meetings Folder", systemImage: "folder") {
                if !NSWorkspace.shared.open(store.dataDirectory) {
                    store.errorMessage = "Could not open the meetings folder in Finder."
                }
            }
        } label: {
            Label("Add Meeting", systemImage: "plus")
        }
        .help("Add Meeting")
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
                store.isFinalizingRecording ? "Saving…" : recordingActive ? "Recording" : "New Recording",
                systemImage: store.isFinalizingRecording
                    ? "hourglass.circle.fill"
                    : recordingActive ? "waveform.circle.fill" : "record.circle.fill"
            )
            .font(.title2)
            .frame(minWidth: 32, minHeight: 32)
            .modifier(RecordingToolbarForeground())
        }
        .labelStyle(.iconOnly).tint(.red)
        .help(recordingActive ? "Show the current recording" : "Choose sources and start a recording")
        .disabled(!store.libraryWritable || store.isStartingRecording || store.isFinalizingRecording)
    }

    private var showsMeetingTabs: Bool {
        selectedMeeting != nil
    }

    @ToolbarContentBuilder private var meetingToolbar: some ToolbarContent {
        if !showsSearchResults && destination == .meetings {
            ToolbarItem(placement: .secondaryAction) { addMeetingMenu }
            if showsMeetingTabs {
                ToolbarItem(placement: .principal) {
                    MeetingContentTabs(selection: $workspace.meetingTab)
                }
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
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
        DefaultToolbarItem(kind: .search, placement: .primaryAction)
    }

    var body: some View {
        // HIG: a sidebar expresses the hierarchy; an intermediate list selects content.
        // Native columns align their titles and actions with the window toolbar.
        // https://developer.apple.com/design/human-interface-guidelines/sidebars
        VStack(spacing: 0) {
            navigationWorkspace
                .navigationSplitViewStyle(.balanced)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Search")
                .searchFocused($searchFocused)
                .onSubmit(of: .search, submitSearch)
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
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .sheet(isPresented: $store.presentsRecordingSetup) {
            RecordingSetupView(onStarted: showMeeting).environmentObject(store)
        }
        .background(PlaybackSpaceKey(playback: playback))
        .focusedSceneValue(\.librarySearchAction, focusLibrarySearch)
        .environment(\.showManagedTask) { id in
            focusedTaskID = id
            showsSearchResults = false
            openedSearchResult = nil
            destination = .tasks
        }
        .task { searchSession.updatePeople(store.people.map { .init(id: $0.id, name: $0.name) }) }
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
            if query.isEmpty, showsSearchResults { showsSearchResults = false }
        }
        .onChange(of: store.recordingID) { _, id in if let id { showMeeting(id) } }
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
                    if await store.deleteMeeting(id: meeting.id), selectedMeeting == meeting.id {
                        selectedMeeting = nil
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
        switch openedSearchResult?.passage?.kind {
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
        let mode = store.settings.defaultSearchMode
        searchSession.updatePeople(store.people.map { .init(id: $0.id, name: $0.name) })
        showsSearchResults = true
        openedSearchResult = nil
        searchFocused = false
        if mode == .text {
            _ = searchSession.submit(query, index: store.libraryIndex, excludingTagIDs: store.excludedTagIDs)
            return
        }
        searchSession.beginPreparation(query, mode: mode)
        let exclusions = store.excludedTagIDs
        searchPreparationTask = Task {
            await searchSession.waitForPeopleResolution()
            guard !Task.isCancelled, searchRequestID == requestID else { return }
            if searchSession.contentQuery.isEmpty {
                searchSession.finishPeopleOnly()
                return
            }
            guard
                let configured = store.settings.serviceProviders.first(where: {
                    $0.id == store.settings.searchProviderID && $0.kind == .localSearch && $0.supports(.search)
                })
            else {
                searchSession.preparationFailed("Choose and prepare a Voice Search provider in Service Providers.")
                return
            }
            do {
                let voice = try await store.voiceSearch.provider(
                    configuration: configured.localSearch ?? LocalSearchConfiguration())
                guard !Task.isCancelled, searchRequestID == requestID else { return }
                var providers: [any SearchProvider] = [voice]
                if mode == .fusion {
                    guard let index = store.libraryIndex else {
                        throw ServiceError("Wait for the library index to finish loading, then try again.")
                    }
                    providers.append(LocalTextSearchProvider(index: index))
                }
                _ = searchSession.submit(query, mode: mode, providers: providers, excludingTagIDs: exclusions)
            }
            catch {
                guard !Task.isCancelled, searchRequestID == requestID else { return }
                searchSession.preparationFailed(error.localizedDescription)
            }
        }
    }

    private var searchModeBinding: Binding<SearchMode> {
        Binding(
            get: { store.settings.defaultSearchMode },
            set: { mode in
                let previous = store.settings
                store.settings.defaultSearchMode = mode
                guard store.saveSettings() else {
                    store.settings = previous
                    return
                }
                if !searchSession.query.isEmpty {
                    search = searchSession.query
                    submitSearch()
                }
            })
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

    private func openSearchResult(_ result: SearchDisplayResult) {
        workspace.selectMeeting(result.meetingID)
        selectedMeeting = result.meetingID
        destination = .meetings
        openedSearchResult = result
        showsSearchResults = false
    }

    private func focusLibrarySearch() {
        searchPresented = true
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
        else {
            Text("No Meeting Selected")
                .font(.title2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
