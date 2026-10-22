import SwiftUI

struct ContextDetailView: View {
    @Environment(\.transcriptLayoutService) private var transcriptLayout
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let title: String
    let personID: UUID?
    let tagID: UUID?
    var reviewingLibrary = false
    @ViewState private var draft = ""
    @ViewState private var selectedMeeting: VoiceExampleRecordingTarget?
    @ViewState private var listSelection: UUID?
    @ViewState private var deleting: Meeting?
    @ViewState private var reviewingVoices = false
    @ViewState private var viewingSamples = false
    @ViewState private var editingProfile = false
    @ViewState private var showsConversation = false
    @StateObject private var loader = AssociatedMeetingLoader()
    private var recordingActive: Bool {
        store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording
    }
    private var person: Person? { store.people.first { $0.id == personID } }
    private var tag: MeetingTag? { store.tags.first { $0.id == tagID } }
    private var displayTitle: String { person?.name ?? tag?.name ?? title }
    private var messages: [ChatMessage] {
        store.contextualChats[MeetingStore.contextChatKey(personID: personID, tagID: tagID)] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader
            if let personID {
                PersonSamplesSummary(library: store.voiceLibrary, personID: personID) { viewingSamples = true }
            }
            Divider()
            HStack {
                Text("Associated Meetings").font(.headline)
                Text(loader.window.page.total.formatted()).foregroundStyle(.secondary)
                Spacer()
                Button("Open Meeting") { if let listSelection { open(listSelection) } }
                    .disabled(listSelection == nil)
            }
            .padding(.horizontal, AppTheme.contentInset).padding(.vertical, 12)
            associatedMeetings
            if let error = loader.error {
                HStack(alignment: .top) {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                    Button("Try Again") {
                        Task { await loader.retry(index: store.libraryIndex, personID: personID, tagID: tagID) }
                    }.disabled(loader.loading)
                }.padding(.horizontal, AppTheme.contentInset).padding(.vertical, 8)
            }
            Divider()
            conversation
        }
        .modifier(
            PersonMatchReviewAvailability(
                library: store.voiceLibrary, personID: personID, reviewingVoices: reviewingLibrary || reviewingVoices)
        )
        .background(AppTheme.readingBackground)
        .focusedValue(\.directoryControlFocus, true)
        .task(id: store.meetingIndexRevision) {
            await loader.refresh(index: store.libraryIndex, personID: personID, tagID: tagID)
        }
        .sheet(isPresented: $reviewingVoices) {
            if let personID {
                PersonMatchReviewView(library: store.voiceLibrary, personID: personID)
            }
        }
        .sheet(isPresented: $viewingSamples) {
            if let personID { PersonSamplesView(library: store.voiceLibrary, personID: personID) }
        }
        .sheet(isPresented: Binding(get: { selectedMeeting != nil }, set: { if !$0 { selectedMeeting = nil } })) {
            if let selectedMeeting {
                MeetingDetailSheet(
                    meetingID: selectedMeeting.id, initialTranscriptRowID: selectedMeeting.transcriptRowID,
                    initialContentTab: selectedMeeting.opensTranscript ? .transcript : nil
                ) { self.selectedMeeting = nil }
            }
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "meeting")” to Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { meeting in
            Button("Move to Trash", role: .destructive) {
                deleting = nil
                Task {
                    if await store.deleteMeeting(id: meeting.id) {
                        transcriptLayout?.remove(meetingID: meeting.id)
                        if listSelection == meeting.id { listSelection = nil }
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("The meeting’s files will move to Trash. You can restore them in Finder.")
        }
    }

    private var identityHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle).font(.title.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                if let person, !person.email.isEmpty {
                    Text(person.email).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if tag?.isExcluded == true {
                    Label("Excluded from Main Lists", systemImage: "eye.slash").font(.callout).foregroundStyle(
                        .secondary)
                }
            }
            Spacer(minLength: 8)
            if personID != nil {
                PersonMatchReviewButton { reviewingVoices = true }
            }
            Menu {
                Button(personID == nil ? "Edit Tag…" : "Edit Profile…") { editingProfile = true }
                if personID != nil {
                    PersonMatchReviewButton { reviewingVoices = true }
                }
            } label: {
                Label(personID == nil ? "Tag Actions" : "Person Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize()
            .popover(isPresented: $editingProfile) { profileEditor }
        }
        .padding(AppTheme.contentInset)
    }

    private var profileEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(personID == nil ? "Edit Tag" : "Edit Profile").font(.headline)
                if let person {
                    Form {
                        CommittedProfileField("Name", value: person.name) { savePersonField(person.id, \.name, $0) }
                        CommittedProfileField("Email", value: person.email) { savePersonField(person.id, \.email, $0) }
                        TextField(
                            "Notes",
                            text: Binding(
                                get: { self.person?.notes ?? "" },
                                set: { store.editPersonNotes(id: person.id, text: $0) }), axis: .vertical
                        )
                        .lineLimit(2...6)
                        .onDisappear { Task { await store.flushProfileNotes() } }
                    }
                    PersonTagsView(personID: person.id)

                }
                if let tag {
                    CommittedProfileField("Name", value: tag.name) { value in
                        Task {
                            guard var updated = self.tag else { return }
                            updated.name = value
                            await store.updateTag(updated)
                        }
                    }
                    Toggle(
                        "Exclude from Main Lists",
                        isOn: Binding(
                            get: { self.tag?.isExcluded ?? false },
                            set: { value in
                                Task {
                                    guard var updated = self.tag else { return }
                                    updated.isExcluded = value
                                    await store.updateTag(updated)
                                }
                            }))
                    Text(
                        "Hide tagged meetings and people from main lists and meeting search. Also hide tasks for those meetings."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder).padding(AppTheme.contentInset)
        }.frame(width: 400, height: personID == nil ? 200 : 430)
    }

    private var associatedMeetings: some View {
        NativeMeetingList(
            entries: loader.window.page.entries, selection: $listSelection,
            recordingID: store.recordingID, isFinalizing: store.isFinalizingRecording,
            playingID: playback.meetingID, isPlaying: playback.isPlaying,
            canPlay: !recordingActive && !playback.isPlaybackBlocked,
            archiveStatuses: store.archiveStatuses,
            viewportChanged: { loader.observe($0, index: store.libraryIndex, personID: personID, tagID: tagID) },
            play: { id in
                playback.requestPlayback(
                    load: {
                        guard await store.ensureMeetingLoaded(id: id), !recordingActive,
                            let meeting = store.meeting(id: id)
                        else { return nil }
                        return meeting
                    },
                    play: { meeting in
                        playback.play(meeting: meeting, files: store.audioURLs(for: meeting))
                    })
            },
            reveal: { id in NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)]) },
            export: { id in
                Task {
                    guard await store.ensureMeetingLoaded(id: id), let meeting = store.meeting(id: id) else { return }
                    MeetingPanels.export(meeting, store: store)
                }
            },
            delete: { id in
                Task {
                    guard await store.ensureMeetingLoaded(id: id) else { return }
                    deleting = store.meeting(id: id)
                }
            }, open: open,
            totalCount: !loader.loading && loader.error == nil && !loader.window.page.hasOlder
                && !loader.window.page.entries.isEmpty ? loader.window.page.total : nil
        )
        .frame(minHeight: 120, maxHeight: .infinity)
        .overlay {
            if loader.window.page.entries.isEmpty {
                if loader.loading {
                    ProgressView("Loading meetings…")
                }
                else if loader.error == nil {
                    ContentUnavailableView(
                        "No Associated Meetings", systemImage: "waveform",
                        description: Text("Meetings appear here when they include this person or tag."))
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if loader.loading && !loader.window.page.entries.isEmpty {
                ProgressView().controlSize(.small).padding(8).accessibilityLabel("Loading more meetings")
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    showsConversation.toggle()
                } label: {
                    Label("Ask About Meetings", systemImage: showsConversation ? "chevron.down" : "chevron.right")
                }.buttonStyle(.borderless)
                    .accessibilityValue(showsConversation ? "Expanded" : "Collapsed")
                Spacer()
                Text("20 most recent meetings").font(.caption).foregroundStyle(.secondary)
            }
            if showsConversation {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == "user" ? "You" : "Gday").font(.headline)
                                Text(message.content).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(height: 130)
            }
            HStack(alignment: .bottom) {
                TextField("Ask a Question", text: $draft, axis: .vertical).lineLimit(1...3).onSubmit(send)
                    .accessibilityLabel("Ask About Recent Meetings")
                Button("Send", systemImage: "arrow.up", action: send)
                    .disabled(!canSend)
            }.textFieldStyle(.roundedBorder)
        }.padding(.horizontal, AppTheme.contentInset).padding(.vertical, 12)
    }

    private func open(_ id: UUID) {
        selectedMeeting = VoiceExampleRecordingTarget(meetingID: id)
    }
    private func savePersonField(_ id: UUID, _ path: WritableKeyPath<Person, String>, _ value: String) {
        Task {
            guard var updated = store.people.first(where: { $0.id == id }), updated[keyPath: path] != value else {
                return
            }
            updated[keyPath: path] = value
            await store.updatePerson(updated)
        }
    }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && loader.window.page.total > 0
            && !store.isJobRunning(
                .contextChat, .context(MeetingStore.contextChatKey(personID: personID, tagID: tagID)))
    }
    private func send() {
        guard canSend else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        showsConversation = true
        Task { _ = await store.sendContextChat(personID: personID, tagID: tagID, message: question) }
    }
}

/// Short profile fields retain a local draft until submission or focus loss.
private struct CommittedProfileField: View {
    let label: String
    let value: String
    let save: (String) -> Void
    @ViewState private var draft: String
    @ViewState private var committed: String
    @FocusState private var focused: Bool

    init(_ label: String, value: String, save: @escaping (String) -> Void) {
        self.label = label
        self.value = value
        self.save = save
        _draft = ViewState(initialValue: value)
        _committed = ViewState(initialValue: value)
    }
    var body: some View {
        TextField(label, text: $draft)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, active in
                if !active { commit() }
            }
            .onChange(of: value) { _, value in
                committed = value
                if !focused { draft = value }
            }
            .onExitCommand {
                draft = committed
                focused = false
            }
            .onDisappear { commit() }
    }
    private func commit() {
        guard draft != committed else { return }
        committed = draft
        save(draft)
    }
}
