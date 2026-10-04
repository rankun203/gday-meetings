import SwiftUI

struct ContextDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.showManagedTask) private var showManagedTask
    let title: String
    let personID: UUID?
    let tagID: UUID?
    @ViewState private var draft = ""
    private var messages: [ChatMessage] {
        store.contextualChats[MeetingStore.contextChatKey(personID: personID, tagID: tagID)] ?? []
    }
    @ViewState private var selectedMeeting: UUID?
    @ViewState private var page = AssociatedMeetingPage()
    @ViewState private var loading = false
    @ViewState private var pageError: String?
    @ViewState private var reviewingVoices = false
    private var meetings: [MeetingListEntry] { page.entries }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title.weight(.semibold)).lineLimit(2).textSelection(.enabled)
            if let personID, let person = store.people.first(where: { $0.id == personID }) {
                PersonVoiceSamplesView(library: store.voiceLibrary, personID: personID) { reviewingVoices = true }
                Form {
                    TextField("Name", text: personBinding(person, \.name))
                    TextField("Email", text: personBinding(person, \.email))
                    TextField("Notes", text: personBinding(person, \.notes), axis: .vertical).lineLimit(1...4)
                }
                PersonTagsView(personID: personID)
            }
            HStack {
                Text(page.total == 1 ? "1 Associated Meeting" : "\(page.total) Associated Meetings").font(.headline)
                Spacer()
                if let tagID {
                    Toggle(
                        "Excluded",
                        isOn: Binding(
                            get: { store.tags.first(where: { $0.id == tagID })?.isExcluded ?? false },
                            set: { excluded in
                                guard var tag = store.tags.first(where: { $0.id == tagID }) else { return }
                                tag.isExcluded = excluded
                                store.updateTag(tag)
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .help("Hide meetings and people with this tag from the main lists and meeting search.")
                }
            }
            List(meetings) { meeting in
                Button {
                    guard store.ensureMeetingLoaded(id: meeting.id) else { return }
                    selectedMeeting = meeting.id
                } label: {
                    HStack {
                        Text(meeting.title)
                        Spacer()
                        Text(meeting.createdAt, style: .date).foregroundStyle(.secondary)
                    }
                }.buttonStyle(ActionButtonStyle())
            }.listStyle(.inset).frame(minHeight: 100, maxHeight: 200)
            HStack {
                Button("Newer") { Task { await load(before: meetings.first) } }
                    .disabled(loading || !page.hasNewer)
                Button("Older") { Task { await load(after: meetings.last) } }
                    .disabled(loading || !page.hasOlder)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text("\(meetings.count) shown").font(.caption).foregroundStyle(.secondary)
            }
            if let pageError {
                HStack {
                    AppInlineMessage(text: pageError, systemImage: "exclamationmark.triangle", tint: .orange)
                    Button("Try Again") { Task { await load() } }.disabled(loading)
                }
            }
            Divider()
            Text("Ask about the 20 most recent meetings").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == "user" ? "You" : "Gday").font(.headline)
                            Text(message.content).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                TextField("Ask a question", text: $draft, axis: .vertical).lineLimit(1...5).onSubmit(send)
                Button("Send", systemImage: "arrow.up", action: send).disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isJobRunning(
                            .contextChat, .context(MeetingStore.contextChatKey(personID: personID, tagID: tagID)))
                        || meetings.isEmpty)
            }
        }.textFieldStyle(.roundedBorder)
            .padding(AppTheme.contentInset).background(AppTheme.readingBackground).navigationTitle(title)
            .focusedValue(\.directoryControlFocus, true)
            .task { await load() }
            .sheet(isPresented: $reviewingVoices) {
                VoiceLibraryView(library: store.voiceLibrary, personID: personID)
            }
            .sheet(isPresented: Binding(get: { selectedMeeting != nil }, set: { if !$0 { selectedMeeting = nil } })) {
                if let selectedMeeting {
                    VStack {
                        HStack {
                            Spacer()
                            Button("Done") { self.selectedMeeting = nil }.keyboardShortcut(.cancelAction)
                        }.padding()
                        MeetingDetailView(meetingID: selectedMeeting)
                    }.frame(width: 800, height: 650)
                        .environment(\.showManagedTask) { id in
                            self.selectedMeeting = nil
                            showManagedTask(id)
                        }
                }
            }
    }
    private func load(after: MeetingListEntry? = nil, before: MeetingListEntry? = nil) async {
        guard !loading, let index = store.libraryIndex else { return }
        loading = true
        defer { loading = false }
        let personID = personID
        let tagID = tagID
        do {
            let next = try await Task.detached(priority: .userInitiated) {
                try AssociatedMeetingPage.read(
                    index: index, personID: personID, tagID: tagID, after: after, before: before)
            }.value
            guard !Task.isCancelled else { return }
            page = next
            pageError = nil
        }
        catch {
            pageError = "Couldn’t load associated meetings. " + error.localizedDescription
        }
    }
    private func personBinding(_ person: Person, _ path: WritableKeyPath<Person, String>) -> Binding<String> {
        Binding(
            get: { store.people.first(where: { $0.id == person.id })?[keyPath: path] ?? "" },
            set: { value in
                guard var updated = store.people.first(where: { $0.id == person.id }) else { return }
                updated[keyPath: path] = value
                store.updatePerson(updated)
            })
    }
    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        Task { _ = await store.sendContextChat(personID: personID, tagID: tagID, message: question) }
    }
}

struct AssociatedMeetingPage {
    var entries: [MeetingListEntry] = []
    var total = 0
    var hasNewer = false
    var hasOlder = false

    static func read(
        index: LibraryIndex, personID: UUID?, tagID: UUID?, after: MeetingListEntry? = nil,
        before: MeetingListEntry? = nil
    ) throws -> Self {
        let entries = try index.page(after: after, before: before, limit: 20, personID: personID, tagID: tagID)
        if entries.isEmpty && (after != nil || before != nil) {
            return try read(index: index, personID: personID, tagID: tagID)
        }
        let total = try index.count(personID: personID, tagID: tagID)
        let newer =
            try entries.first.map { !(try index.page(before: $0, limit: 1, personID: personID, tagID: tagID)).isEmpty }
            ?? false
        let older =
            try entries.last.map { !(try index.page(after: $0, limit: 1, personID: personID, tagID: tagID)).isEmpty }
            ?? false
        return Self(entries: entries, total: total, hasNewer: newer, hasOlder: older)
    }
}
