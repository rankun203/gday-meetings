import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryDestination: Hashable { case meetings, people, tags }

struct LibraryView: View {
    /// Splits after the first sentence; a single-sentence message has no body.
    static func alertParts(_ text: String?) -> (title: String, message: String) {
        let text = text ?? ""
        guard let end = text.range(of: ". ") else { return (text, "") }
        return (String(text[..<end.lowerBound]) + ".", String(text[end.upperBound...]))
    }
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @ViewState private var destination: LibraryDestination? = .meetings
    @ViewState private var selectedMeeting: UUID?
    @ViewState private var selectedPerson: UUID?
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
        selectedMeeting = id
        destination = .meetings
    }

    private var filteredMeetings: [Meeting] {
        store.meetings.filter { meeting in
            search.isEmpty
                || ([meeting.title, NotesDocument(meeting.notes).text, meeting.summary] + meeting.transcript.map(\.text))
                    .joined(
                        separator: " "
                    ).localizedCaseInsensitiveContains(search)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @ViewBuilder private var emptyMeetings: some View {
        if store.newerLibraryVersion != nil {
            // The library is read-only; recording and import would not be saved.
            ContentUnavailableView(
                NewerLibraryVersionError.title, systemImage: "exclamationmark.triangle",
                description: Text(NewerLibraryVersionError.recovery))
        }
        else {
            meetingsPlaceholder
        }
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
                            set: { if sidebarRowsVisible { destination = $0 } })
                    ) {
                        Group {
                            Label("Meetings", systemImage: "waveform").tag(LibraryDestination.meetings)
                            Label("People", systemImage: "person.2").tag(LibraryDestination.people)
                            Label("Tags", systemImage: "tag").tag(LibraryDestination.tags)
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
                HSplitView {
                    Group {
                        switch destination {
                        case .people: PeopleView(selection: $selectedPerson)
                        case .tags: TagsView(selection: $selectedTag)
                        default:
                            ScrollViewReader { scroll in
                                List(selection: $selectedMeeting) {
                                    ForEach(filteredMeetings) { meeting in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(meeting.title).font(.headline).lineLimit(1)
                                                if store.recordingID == meeting.id {
                                                    Label(
                                                        store.isFinalizingRecording ? "Saving audio" : "Recording",
                                                        systemImage: store.isFinalizingRecording
                                                            ? "externaldrive" : "record.circle"
                                                    ).foregroundStyle(
                                                        store.isFinalizingRecording ? Color.secondary : Color.red
                                                    ).labelStyle(.iconOnly)
                                                }
                                                else if playback.meetingID == meeting.id {
                                                    Image(
                                                        systemName: playback.isPlaying
                                                            ? "speaker.wave.2.fill" : "pause.circle"
                                                    ).foregroundStyle(.tint).accessibilityLabel(
                                                        playback.isPlaying ? "Playing" : "Playback paused")
                                                }
                                            }
                                            HStack(spacing: 6) {
                                                Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                                                if meeting.duration > 0 {
                                                    Text("·")
                                                    Text(playbackTime(meeting.duration)).monospacedDigit()
                                                }
                                                if let archive = store.archiveStatuses[meeting.id] {
                                                    MeetingArchiveListIcon(status: archive)
                                                }
                                            }.font(.caption).foregroundStyle(.secondary)
                                            if !meeting.summary.isEmpty {
                                                Text(meeting.summary).lineLimit(2).font(.caption).foregroundStyle(
                                                    .secondary)
                                            }
                                        }.padding(.vertical, 4).tag(meeting.id)
                                    }
                                }
                                .listStyle(.inset)
                                .contentMargins(.top, 0, for: .scrollContent)
                                .scrollBounceBehavior(.basedOnSize)
                                // Native primary action: single click selects, double click plays.
                                // https://developer.apple.com/documentation/swiftui/view/contextmenu(forselectiontype:menu:primaryaction:)
                                .contextMenu(forSelectionType: UUID.self) { ids in
                                    if let id = ids.first, let meeting = store.meetings.first(where: { $0.id == id }) {
                                        if !meeting.audioFiles.isEmpty {
                                            Button("Play", systemImage: "play.fill") {
                                                playback.play(meeting: meeting, files: store.audioURLs(for: meeting))
                                            }
                                            .disabled(recordingActive)
                                        }
                                        Button("Export Meeting…") { MeetingPanels.export(meeting, store: store) }
                                        Button("Delete Meeting…", role: .destructive) { deleting = meeting }
                                            .disabled(store.recordingID == meeting.id)
                                    }
                                } primaryAction: { ids in
                                    guard !recordingActive, let id = ids.first,
                                        let meeting = store.meetings.first(where: { $0.id == id })
                                    else { return }
                                    let files = store.audioURLs(for: meeting)
                                    guard !files.isEmpty else { return }
                                    playback.play(meeting: meeting, files: files)
                                }
                                .modifier(AudioFileDrop())
                                .navigationTitle("Meetings")
                                .overlay { if filteredMeetings.isEmpty { emptyMeetings } }
                                .onChange(of: store.meetings.map(\.id)) { previous, current in
                                    // Inserting above the visible rows can retain the native list's
                                    // old scroll position, leaving the new first row partly clipped.
                                    // Reveal additions without changing selection or playback. Edits,
                                    // deletions, search changes and track imports keep their position.
                                    let existing = Set(previous)
                                    guard current.contains(where: { !existing.contains($0) }),
                                        let added = filteredMeetings.first(where: { !existing.contains($0.id) })
                                    else { return }
                                    // Center the added row. For the first row, native scrolling
                                    // clamps to the document beginning, preserving the list inset.
                                    // Top or minimum alignment scrolls that native space away.
                                    scroll.scrollTo(added.id, anchor: .center)
                                }
                            }
                        }
                    }.frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                    Group {
                        if destination == .meetings, let id = selectedMeeting,
                            store.meetings.contains(where: { $0.id == id })
                        {
                            MeetingDetailView(meetingID: id).id(id)
                        }
                        else if destination == .people, let id = selectedPerson,
                            let person = store.people.first(where: { $0.id == id })
                        {
                            ContextDetailView(title: person.name, personID: id, tagID: nil).id(id)
                        }
                        else if destination == .tags, let id = selectedTag,
                            let tag = store.tags.first(where: { $0.id == id })
                        {
                            ContextDetailView(title: tag.name, personID: nil, tagID: id).id(id)
                        }
                        else {
                            emptySelection
                        }
                    }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
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
                    Text(destinationTitle).font(.headline)
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
                // Progress for background jobs, including during a recording. It shows
                // the newest job and a count of the others, and disappears when all end.
                if !store.backgroundJobs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if store.backgroundJobs.count > 1 {
                            Text("\(store.backgroundJobs.count - 1) more in progress").font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                        .accessibilityElement(children: .combine)
                        .help(store.backgroundJobs.map(store.progressText).joined(separator: "\n"))
                }
            }
        }
        .sheet(isPresented: $store.presentsRecordingSetup) {
            RecordingSetupView(onStarted: showMeeting).environmentObject(store)
        }
        .background(PlaybackSpaceKey(playback: playback))
        .onAppear {
            sidebarControl?.connect(
                expanded: $sidebarExpanded, rows: $sidebarRowsVisible, toggle: toggleSidebar(reduceMotion:))
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
        .confirmationDialog(
            "Delete \(deleting?.title ?? "meeting")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                if let meeting = deleting {
                    store.deleteMeeting(id: meeting.id)
                    if selectedMeeting == meeting.id { selectedMeeting = nil }
                }
                deleting = nil
            }
        } message: {
            Text("This deletes the meeting and its saved audio. This cannot be undone.")
        }
    }

    private var destinationTitle: String {
        switch destination {
        case .people: "People"
        case .tags: "Tags"
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
                if store.isStartingRecording || store.isFinalizingRecording {
                    ProgressView().controlSize(.small)
                }
                else {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.title2).accessibilityHidden(
                        true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        store.isStartingRecording
                            ? "Preparing Recording" : store.isFinalizingRecording ? "Saving Recording" : "Recording"
                    )
                    .font(.callout.weight(.semibold))
                    if let id = store.recordingID, let meeting = store.meetings.first(where: { $0.id == id }) {
                        Button(meeting.title) { showMeeting(id) }.buttonStyle(ActionButtonStyle()).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1).help("Return to this recording")
                    }
                    else {
                        Text("Complete the macOS audio consent prompt.").font(.caption).foregroundStyle(.secondary)
                    }
                }
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
