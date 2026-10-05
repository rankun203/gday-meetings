import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryDestination: Hashable { case meetings, people, tags, tasks, agents }

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
    @ViewState private var selectedPeople: Set<UUID> = []
    @ViewState private var selectedTag: UUID?
    @ViewState private var search = ""
    @StateObject private var searchSession = LibrarySearchSession()
    @ViewState private var showsSearchResults = false
    @ViewState private var openedSearchResult: LibrarySearchResult?
    @FocusState private var searchFocused: Bool
    @ViewState private var deleting: Meeting?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var sidebarExpanded = true
    @ViewState private var sidebarRowsVisible = true
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
        guard store.ensureMeetingLoaded(id: id) else { return }
        showsSearchResults = false
        openedSearchResult = nil
        selectedMeeting = id
        destination = .meetings
    }

    private var filteredMeetings: [MeetingListEntry] { store.visibleMeetingEntries }

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
        NativeMeetingList(
            entries: filteredMeetings, selection: $selectedMeeting, revealID: store.latestCreatedMeetingID,
            recordingID: store.recordingID, isFinalizing: store.isFinalizingRecording,
            playingID: playback.meetingID, isPlaying: playback.isPlaying, canPlay: !recordingActive,
            archiveStatuses: store.archiveStatuses,
            displaySummaryTitle: displaySummaryTitleOnMeetings,
            viewportChanged: { store.prefetchMeetings($0) },
            play: { id in
                guard !recordingActive, let meeting = store.meeting(id: id) else { return }
                let files = store.audioURLs(for: meeting)
                if !files.isEmpty { playback.play(meeting: meeting, files: files) }
            },
            reveal: { id in NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)]) },
            export: { id in if let meeting = store.meeting(id: id) { MeetingPanels.export(meeting, store: store) } },
            delete: { id in deleting = store.meeting(id: id) }
        )
        .modifier(AudioFileDrop())
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
                    Text(error).font(.caption)
                    Button("Try Again") { Task { await store.searchMeetingPages("") } }
                }.padding(12).background(.regularMaterial)
            }
        }
        .onChange(of: store.latestCreatedMeetingID) { _, id in
            if let id, !store.visibleMeetingIDs.contains(id) { store.resetMeetingPages() }
        }
    }

    var body: some View {
        // HIG: a sidebar expresses the hierarchy; an intermediate list selects content.
        // Content columns are independent of the window toolbar.
        // https://developer.apple.com/design/human-interface-guidelines/sidebars
        VStack(spacing: 0) {
            NavigationSplitView(
                columnVisibility: Binding(
                    get: { sidebarExpanded ? .all : .detailOnly },
                    set: { value in
                        sidebarExpanded = value != .detailOnly
                        sidebarRowsVisible = sidebarExpanded
                    })
            ) {
                VStack(spacing: AppTheme.compactSpacing) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .accessibilityLabel("Search meetings and transcripts")
                            .help("Search meetings and transcripts. Press Return to search.")
                            .onSubmit(submitSearch)
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear Search").help("Clear Search")
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8).padding(.top, 10)
                    List(
                        selection: Binding(
                            get: { sidebarRowsVisible && !showsSearchResults ? destination : nil },
                            set: {
                                if sidebarRowsVisible, let chosen = $0 {
                                    focusedTaskID = nil
                                    showsSearchResults = false
                                    openedSearchResult = nil
                                    destination = chosen
                                }
                            })
                    ) {
                        Group {
                            Label("Meetings", systemImage: "waveform").tag(LibraryDestination.meetings)
                            Label("People", systemImage: "person.2").tag(LibraryDestination.people)
                            Label("Tags", systemImage: "tag").tag(LibraryDestination.tags)
                            Label("Tasks", systemImage: "list.bullet.rectangle").tag(LibraryDestination.tasks)
                            Label("Agents", systemImage: "bubble.left.and.text.bubble.right").tag(
                                LibraryDestination.agents)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    // The native list already supplies row spacing. An extra scroll margin
                    // alternates between applied/unapplied on focus and state updates.
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            } detail: {
                if showsSearchResults {
                    LibrarySearchResultsView(session: searchSession, open: openSearchResult, retry: retrySearch)
                }
                else if destination == .tasks {
                    TaskQueueView(showMeeting: showMeeting, focusedTaskID: focusedTaskID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else if destination == .agents {
                    AgentsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    GeometryReader { workspace in
                        let maximumListWidth = min(360, max(250, workspace.size.width - 361))
                        HSplitView {
                            Group {
                                switch destination {
                                case .people: PeopleView(selection: $selectedPeople)
                                case .tags: TagsView(selection: $selectedTag)
                                default:
                                    VStack(spacing: 0) {
                                        WorkspaceListHeader(title: "Meetings") {
                                            Menu {
                                                Button("New Meeting Notes", systemImage: "square.and.pencil") {
                                                    showMeeting(store.createMeeting(title: "Untitled Meeting"))
                                                }
                                                Button("Import Audio or Video…", systemImage: "square.and.arrow.down") {
                                                    MeetingPanels.importAudio(store)
                                                }
                                                .disabled(recordingActive || store.isImportingAudio)
                                                Divider()
                                                Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }
                                                Button("Import Existing Gday Library…") {
                                                    MeetingPanels.importLegacy(store)
                                                }
                                            } label: {
                                                Label("Add Meeting", systemImage: "plus")
                                            }
                                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                                            .fixedSize().help("Add Meeting")
                                            .disabled(!store.libraryWritable)
                                        }
                                        meetingList
                                    }
                                }
                            }.frame(
                                minWidth: 250, idealWidth: min(300, maximumListWidth),
                                maxWidth: maximumListWidth
                            )
                            .background(AppTheme.readingBackground)
                            Group {
                                if destination == .meetings, let id = selectedMeeting,
                                    store.meetings.contains(where: { $0.id == id })
                                {
                                    VStack(spacing: 0) {
                                        if openedSearchResult != nil {
                                            HStack {
                                                Button("Back to Search Results", systemImage: "chevron.left") {
                                                    showsSearchResults = true
                                                    search = searchSession.query
                                                }
                                                Spacer()
                                            }.padding(.horizontal, AppTheme.contentInset).padding(
                                                .top, AppTheme.contentSpacing)
                                        }
                                        MeetingDetailView(
                                            meetingID: id,
                                            initialTranscriptRowID: openedSearchResult?.segmentID,
                                            initialContentTab: searchContentTab
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
                            }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                                .background(AppTheme.readingBackground)
                        }
                    }
                    // Keep a remembered native divider position inside the space
                    // allocated by navigation, including at the minimum window width.
                    .frame(minWidth: 611)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle("")
            // HIG: toolbar actions apply to the current content and use familiar symbols.
            // https://developer.apple.com/design/human-interface-guidelines/toolbars
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
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
                            systemImage: "record.circle.fill"
                        )
                        .modifier(RecordingToolbarForeground())
                    }
                    .labelStyle(.titleAndIcon).tint(.red)
                    .help(recordingActive ? "Show the current recording" : "Choose sources and start a recording")
                    // A read-only library can't save a recording, import, or new notes.
                    // Background jobs such as transcription never disable it.
                    .disabled(!store.libraryWritable || store.isStartingRecording || store.isFinalizingRecording)
                    Menu {
                        Button("Open Meetings Folder", systemImage: "folder") {
                            if !NSWorkspace.shared.open(store.dataDirectory) {
                                store.errorMessage = "Could not open the meetings folder in Finder."
                            }
                        }
                    } label: {
                        Label("Library", systemImage: "folder")
                    }
                    .help("Library")
                    Button(action: focusLibrarySearch) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search meetings and transcripts")
                    .keyboardShortcut("f", modifiers: .command)
                }
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
        .sheet(isPresented: $store.presentsRecordingSetup) {
            RecordingSetupView(onStarted: showMeeting).environmentObject(store)
        }
        .background(PlaybackSpaceKey(playback: playback))
        .environment(\.showManagedTask) { id in
            focusedTaskID = id
            showsSearchResults = false
            openedSearchResult = nil
            destination = .tasks
        }
        .onAppear {
            if let selectedMeeting { _ = store.ensureMeetingLoaded(id: selectedMeeting) }
            sidebarControl?.connect(
                expanded: $sidebarExpanded, rows: $sidebarRowsVisible, toggle: toggleSidebar(reduceMotion:))
        }
        .onChange(of: selectedMeeting) { _, id in
            if openedSearchResult?.meetingID != id { openedSearchResult = nil }
            if let id { _ = store.ensureMeetingLoaded(id: id) }
        }
        .onDisappear { sidebarControl?.disconnect() }
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
                if store.deleteMeeting(id: meeting.id), selectedMeeting == meeting.id { selectedMeeting = nil }
                deleting = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { deleting = nil }
                .keyboardShortcut(.cancelAction)
        } message: { _ in
            Text("The meeting and its saved files will be moved to the Trash. You can restore them in Finder.")
        }
    }

    private var searchContentTab: MeetingContentTab? {
        switch openedSearchResult?.kind {
        case .notes: .notes
        case .summary: .summary
        case .transcript: .transcript
        default: nil
        }
    }

    private func submitSearch() {
        if searchSession.submit(search, index: store.libraryIndex, excludingTagIDs: store.excludedTagIDs) {
            showsSearchResults = true
            openedSearchResult = nil
            searchFocused = false
        }
    }

    private func retrySearch() {
        if searchSession.results.isEmpty {
            _ = searchSession.submit(
                searchSession.query, index: store.libraryIndex, excludingTagIDs: store.excludedTagIDs)
        }
        else {
            searchSession.retry()
        }
    }

    private func openSearchResult(_ result: LibrarySearchResult) {
        guard store.ensureMeetingLoaded(id: result.meetingID) else { return }
        selectedMeeting = result.meetingID
        destination = .meetings
        openedSearchResult = result
        showsSearchResults = false
    }

    private func focusLibrarySearch() {
        if !sidebarExpanded {
            sidebarTransition = UUID()
            sidebarExpanded = true
            sidebarRowsVisible = true
        }
        searchFocused = true
    }

    private func toggleSidebar() { toggleSidebar(reduceMotion: reduceMotion) }

    private func toggleSidebar(reduceMotion: Bool) {
        let transition = UUID()
        sidebarTransition = transition
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25), completionCriteria: .removed) {
            sidebarExpanded.toggle()
            sidebarRowsVisible = sidebarExpanded
        } completion: {
            guard sidebarTransition == transition else { return }
            sidebarRowsVisible = sidebarExpanded
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
            VStack(spacing: 18) {
                Button {
                    store.presentsRecordingSetup = true
                } label: {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)
                        .frame(width: 88, height: 88)
                        .contentShape(Circle())
                }
                .buttonStyle(ActionButtonStyle(cornerRadius: 44))
                .accessibilityLabel("New Recording")
                .help("New Recording")
                .disabled(!store.canStartRecording)
                Text("Select a meeting or start a recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
            do {
                _ = try store.importLegacyLibrary(url: url)
            }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    static func importArchive(_ store: MeetingStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.importArchive(url: url) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    static func export(_ meeting: Meeting, store: MeetingStore) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title + ".json"
        let formats = MeetingExportPanel(panel: panel)
        if withExtendedLifetime(formats, { panel.runModal() }) == .OK, let url = panel.url {
            do { try store.exportMeeting(id: meeting.id, to: url) }
            catch {
                store.errorMessage = error.localizedDescription
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
