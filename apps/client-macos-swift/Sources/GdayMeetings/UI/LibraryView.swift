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
        selectedMeeting = id
        destination = .meetings
    }

    private var filteredMeetings: [MeetingListEntry] { store.visibleMeetingEntries }

    private var emptyMeetings: some View {
        LibraryIndexPlaceholder(status: store.libraryDataStatus) { meetingsPlaceholder }
    }

    private var meetingsPlaceholder: some View {
        let title = search.isEmpty ? "No Meetings" : "No Results"
        let description = search.isEmpty ? "Record a meeting or import audio to get started." : "Try another search."
        return ContentUnavailableView {
            Label(title, systemImage: "waveform")
        } description: {
            Text(description)
        } actions: {
            if search.isEmpty {
                Button("New Recording") { store.presentsRecordingSetup = true }
                    .disabled(!store.canStartRecording)
            }
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
                    Button("Try Again") { Task { await store.searchMeetingPages(search) } }
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
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(
                        selection: Binding(
                            get: { sidebarRowsVisible ? destination : nil },
                            set: {
                                if sidebarRowsVisible {
                                    focusedTaskID = nil
                                    destination = $0
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
                        .opacity(sidebarRowsVisible ? 1 : 0)
                        .animation(nil, value: sidebarRowsVisible)
                    }
                    .listStyle(.sidebar)
                    // The native list already supplies row spacing. An extra scroll margin
                    // alternates between applied/unapplied on focus and state updates.
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollBounceBehavior(.basedOnSize)
                    .allowsHitTesting(sidebarRowsVisible)
                    .accessibilityHidden(!sidebarRowsVisible)
                }
                .frame(width: 180)
                .background(.bar)
                .frame(width: sidebarExpanded ? 180 : 0, alignment: .leading)
                .clipped()
                if destination == .tasks {
                    TaskQueueView(showMeeting: showMeeting, focusedTaskID: focusedTaskID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else if destination == .agents {
                    AgentsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    HSplitView {
                        Group {
                            switch destination {
                            case .people: PeopleView(selection: $selectedPeople)
                            case .tags: TagsView(selection: $selectedTag)
                            default:
                                meetingList
                            }
                        }.frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        Group {
                            if destination == .meetings, let id = selectedMeeting,
                                store.meetings.contains(where: { $0.id == id })
                            {
                                MeetingDetailView(meetingID: id).id(id)
                            }
                            else if destination == .people, selectedPeople.count == 1, let id = selectedPeople.first,
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
                    }
                }
            }
            .navigationTitle("")
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            // HIG: toolbar actions apply to the current content and use familiar symbols.
            // https://developer.apple.com/design/human-interface-guidelines/toolbars
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: toggleSidebar) {
                        Label(sidebarExpanded ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                    }
                    .help(sidebarExpanded ? "Hide Sidebar" : "Show Sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                }
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 6) {
                        if destination == .meetings {
                            Image(nsImage: MenuBarArtwork.normal)
                                .renderingMode(.template)
                                .accessibilityHidden(true)
                            Text("Gday Meetings")
                        }
                        else {
                            Text(destinationTitle)
                        }
                    }
                    .font(.headline)
                    .modifier(LibraryToolbarTitleForeground())
                    .accessibilityElement(children: .combine)
                }
                ToolbarItemGroup {
                    Spacer()
                    Button {
                        if !NSWorkspace.shared.open(store.dataDirectory) {
                            store.errorMessage = "Could not open the meetings folder in Finder."
                        }
                    } label: {
                        Label("Open Meetings Folder", systemImage: "folder")
                    }
                    .help("Open the meetings storage folder in Finder")
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
                    Button {
                        MeetingPanels.importAudio(store)
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import an audio or video file")
                    .disabled(
                        !store.libraryWritable || recordingActive || store.isImportingAudio)
                    Menu {
                        Button("New Meeting Notes", systemImage: "square.and.pencil") {
                            showMeeting(store.createMeeting(title: "Untitled Meeting"))
                        }
                        Divider()
                        Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }
                        Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }
                    } label: {
                        Label("Library Actions", systemImage: "ellipsis")
                    }
                    .help("New notes and library imports").disabled(!store.libraryWritable)
                    if destination == .meetings {
                        HStack(spacing: 4) {
                            Button {
                                searchFocused = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(ActionButtonStyle()).help("Search meetings and transcripts")
                            .accessibilityLabel("Search meetings and transcripts")
                            .keyboardShortcut("f", modifiers: .command)
                            TextField("Search meetings and transcripts", text: $search)
                                .textFieldStyle(.plain).focused($searchFocused)
                                .accessibilityLabel("Search meetings and transcripts")
                            if !search.isEmpty {
                                Button {
                                    search = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(ActionButtonStyle()).accessibilityLabel("Clear search").help(
                                    "Clear search")
                            }
                        }
                        .padding(6)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: 220)
                    }
                }
                ToolbarItem(id: "meeting-actions", placement: .automatic) {
                    if destination == .meetings, let meeting = store.meetings.first(where: { $0.id == selectedMeeting })
                    {
                        MeetingActionsMenu(meeting: meeting)
                    }
                }
            }
            // HIG Feedback: keep the activity visible while people browse other content.
            // A single persistent transport replaces scattered status and action rows.
            // https://developer.apple.com/design/human-interface-guidelines/feedback
            // Allocate actual layout height so detail overlays cannot extend beneath playback.
            VStack(spacing: 0) {
                if recordingActive
                    && (store.isStartingRecording || destination != .meetings || selectedMeeting != store.recordingID)
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
            destination = .tasks
        }
        .onAppear {
            if let selectedMeeting { _ = store.ensureMeetingLoaded(id: selectedMeeting) }
            sidebarControl?.connect(
                expanded: $sidebarExpanded, rows: $sidebarRowsVisible, toggle: toggleSidebar(reduceMotion:))
        }
        .task(id: search) { await store.searchMeetingPages(search) }
        .onChange(of: selectedMeeting) { _, id in
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

    private var destinationTitle: String {
        switch destination {
        case .people: "People"
        case .tags: "Tags"
        case .tasks: "Tasks"
        case .agents: "Agents"
        default: "Meetings"
        }
    }

    private func toggleSidebar() { toggleSidebar(reduceMotion: reduceMotion) }

    private func toggleSidebar(reduceMotion: Bool) {
        let transition = UUID()
        sidebarTransition = transition
        sidebarRowsVisible = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25), completionCriteria: .removed) {
            sidebarExpanded.toggle()
        } completion: {
            guard sidebarTransition == transition else { return }
            sidebarRowsVisible = sidebarExpanded
            sidebarControl?.completed?(sidebarExpanded)
        }
    }

    private var emptySelection: some View {
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

private struct LibraryToolbarTitleForeground: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(nsColor: appearsActive ? .labelColor : .disabledControlTextColor))
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
